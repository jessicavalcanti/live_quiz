defmodule LiveQuiz.Mail do
  @moduledoc """
  The outbox: messages are written down, then sent.

  Three flows here mint a token and mail a link — confirming an account,
  changing an address, resetting a password. The token was durable and the send
  was not, so a slow provider made the interface slow and a provider that was
  down made it *lie*: the caller discarded the failure and the screen said the
  message was on its way (R07).

  So the order is reversed. `record/1` writes the intent, in the same
  transaction as the token, and returns; `LiveQuiz.Mail.Courier` drains the
  table. The interface no longer waits on SMTP, and "we sent it" means a row
  exists that says so.

  ## Idempotency

  Every intent carries a `dedupe_key` under a unique index. A caller that runs
  twice — a double submit, a retried transaction — records one message. The key
  is derived from the token, so the same *token* is mailed once and a genuinely
  new request, which mints a new token, is genuinely a new message.

  ## Bounded retry

  #{5} attempts, backing off 30s, 2min, 10min and an hour. A row is claimed by
  moving its `deliver_after` forward before the send, so a courier that dies
  mid-send costs one attempt rather than a stuck row, and two couriers — during
  a rolling restart — cannot both take the same one.

  Attempts stop at the *token's* expiry as well as at the count: retrying past
  it would deliver a dead link, which is worse than not writing, because it
  looks like the system worked.

  ## Observability

  `[:live_quiz, :mail, :sent | :failed | :exhausted | :expired]`, each carrying
  the `kind` of the message. Never the body, never the address: the body is a
  live link and the address is the person.
  """

  import Ecto.Query

  alias LiveQuiz.Mail.Delivery
  alias LiveQuiz.Mailer
  alias LiveQuiz.Repo

  require Logger

  @max_attempts 5
  @backoff_seconds [30, 120, 600, 3600]
  # How long a claimed row stays invisible. Longer than any send should take,
  # short enough that a courier killed mid-send is not a message lost for the
  # afternoon.
  @claim_seconds 120
  @batch 20

  @doc "How many times one message is attempted before it is given up on."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts

  @doc """
  Writes down a message to send.

  `attrs` needs `:recipient`, `:subject`, `:body`, `:kind`, `:dedupe_key` and
  `:expires_at`; `:user_id` when there is an account behind it. Recording the
  same `dedupe_key` twice is not an error and does not queue a second message.
  """
  @spec record(map()) :: {:ok, Delivery.t()} | {:error, Ecto.Changeset.t()}
  def record(attrs) do
    attrs = Map.put_new(attrs, :deliver_after, DateTime.utc_now(:second))

    %Delivery{}
    |> Delivery.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :dedupe_key)
    |> case do
      # `on_conflict: :nothing` answers with an unpersisted struct when the row
      # was already there. The message is owed either way, which is all the
      # caller asked for.
      {:ok, %Delivery{id: nil}} -> {:ok, Repo.get_by!(Delivery, dedupe_key: attrs.dedupe_key)}
      other -> other
    end
  end

  @doc """
  Nudges the courier, or does the work here, depending on the mode.

  `:async` — production — hands the drain to `LiveQuiz.Mail.Courier`, so the
  request that recorded the message never waits on a provider. `:inline`, which
  is the mode in `:test`, drains in the calling process, so a test that records
  a message can then assert it was sent without racing a process.
  """
  @spec deliver_soon() :: :ok
  def deliver_soon do
    case mode() do
      :inline ->
        drain(DateTime.utc_now(:second))

        :ok

      :async ->
        LiveQuiz.Mail.Courier.nudge()
    end
  end

  @doc "The delivery mode: `:async` in production, `:inline` in `:test`."
  @spec mode() :: :async | :inline
  def mode do
    :live_quiz
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:mode, :async)
  end

  @doc """
  Sends everything that is due, in batches, until nothing is.

  Answers with how many messages left the building.
  """
  @spec drain(DateTime.t()) :: non_neg_integer()
  def drain(now \\ DateTime.utc_now(:second)) do
    now
    |> drop_expired()
    |> then(fn _dropped -> claim(now) end)
    |> case do
      [] -> 0
      claimed -> Enum.count(claimed, &attempt(&1, now)) + drain(now)
    end
  end

  @doc "How many messages are still owed. For tests and for a health check."
  @spec pending_count() :: non_neg_integer()
  def pending_count, do: Repo.aggregate(Delivery, :count)

  # Claiming and sending are separate on purpose: holding a database connection
  # open across an SMTP conversation is how a slow provider becomes an outage of
  # everything else. `SKIP LOCKED` is what lets two couriers run during a
  # rolling restart without either waiting on the other.
  defp claim(now) do
    due =
      from(d in Delivery,
        where: d.deliver_after <= ^now,
        order_by: [asc: d.deliver_after],
        limit: @batch,
        lock: "FOR UPDATE SKIP LOCKED",
        select: d.id
      )

    {_count, claimed} =
      Repo.update_all(
        from(d in Delivery, where: d.id in subquery(due), select: d),
        inc: [attempts: 1],
        set: [deliver_after: DateTime.add(now, @claim_seconds, :second), updated_at: now]
      )

    claimed
  end

  defp attempt(%Delivery{} = delivery, now) do
    case Mailer.deliver(email_of(delivery)) do
      {:ok, _metadata} ->
        Repo.delete_all(from(d in Delivery, where: d.id == ^delivery.id))
        emit(:sent, delivery)

        true

      {:error, reason} ->
        give_up_or_retry(delivery, reason, now)

        false
    end
  end

  defp give_up_or_retry(%Delivery{attempts: attempts} = delivery, reason, _now)
       when attempts >= @max_attempts do
    Repo.delete_all(from(d in Delivery, where: d.id == ^delivery.id))
    emit(:exhausted, delivery)

    Logger.error(
      "giving up on a #{delivery.kind} email after #{attempts} attempts: #{inspect(reason)}"
    )
  end

  defp give_up_or_retry(%Delivery{} = delivery, reason, now) do
    Repo.update_all(
      from(d in Delivery, where: d.id == ^delivery.id),
      set: [
        deliver_after: DateTime.add(now, backoff(delivery.attempts), :second),
        last_error: inspect(reason),
        updated_at: now
      ]
    )

    emit(:failed, delivery)
  end

  # Past the life of the link, sending is worse than not sending: the person
  # gets a message that does not work and reads the failure as their own.
  defp drop_expired(now) do
    {dropped, kinds} =
      Repo.delete_all(from(d in Delivery, where: d.expires_at <= ^now, select: d.kind))

    for kind <- kinds do
      :telemetry.execute([:live_quiz, :mail, :expired], %{count: 1}, %{kind: kind})
    end

    dropped
  end

  defp backoff(attempts) do
    Enum.at(@backoff_seconds, attempts - 1, List.last(@backoff_seconds))
  end

  defp email_of(%Delivery{} = delivery) do
    Swoosh.Email.new()
    |> Swoosh.Email.to(delivery.recipient)
    |> Swoosh.Email.from({"Live Quiz", from_address()})
    |> Swoosh.Email.subject(delivery.subject)
    |> Swoosh.Email.text_body(delivery.body)
  end

  @doc "The address messages are sent from."
  @spec from_address() :: String.t()
  def from_address do
    :live_quiz
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:from, "nao-responda@livequiz.dev")
  end

  defp emit(event, %Delivery{} = delivery) do
    :telemetry.execute([:live_quiz, :mail, event], %{attempts: delivery.attempts}, %{
      kind: delivery.kind
    })
  end
end
