defmodule LiveQuiz.RateLimit do
  @moduledoc """
  A budget per operation, identity and origin, so an open endpoint stays open.

  Four things this application does are expensive for the person asking and
  cheap for the person abusing them: checking a password costs a bcrypt hash,
  asking for a reset link costs an email, guessing a join code costs a query,
  and answering a question takes the lock of the room. None of them had a
  budget (R05).

  ## The shape of a budget

  A budget is `{limit, window}`: how many attempts, over how long. Windows are
  fixed — the counter is keyed by `div(now, window)` and simply starts over —
  which is the cheap way to do this and has one honest consequence: somebody
  who spends a whole budget at the end of one window and another at the start
  of the next gets twice the limit across that boundary. For budgets of this
  size that is not the difference between safe and unsafe, and the alternative
  costs a timestamp list per key.

  ## What a key is

  Never just the origin. An IP address is shared by a school, an office and a
  household, so limiting only by IP punishes a room full of legitimate players
  for one of them. Login and password recovery are limited by **both** the
  origin and the account named, and the tighter of the two answers; answering
  is limited by the **participation**, so one participant cannot cost their
  room its lock, which is the thing the review asked for by name.

  ## What it stores, and for how long

  One ETS row per key per window: a tuple and an integer. Rows of past windows
  are swept every #{60} seconds, so what is held is proportional to the
  distinct keys *currently* attempting, not to everyone who ever did.

  Above `#{100_000}` rows the limiter stops counting and lets requests through,
  emitting `[:live_quiz, :rate_limit, :overflow]`. That is deliberate: a
  limiter that turns memory pressure into an outage has become the attack. The
  cap is high enough that reaching it is itself the signal.

  ## Where it does not reach

  The table is local to the node. With one instance — how this is deployed —
  that is the whole system. With several behind a balancer each holds its own
  budget, so the effective limit multiplies by the number of nodes; a shared
  counter (Redis, or a CRDT across the cluster) is the change to make then, and
  the call sites here would not move.
  """

  use GenServer

  @table __MODULE__
  @sweep_every :timer.seconds(60)
  @max_rows 100_000

  # {limit, window in milliseconds}. One place, so a budget can be read off
  # rather than reconstructed from its call site.
  @budgets %{
    # A person entering their own password mistypes it a handful of times. Ten
    # bcrypt hashes a minute from one origin is far above that and far below
    # what makes the hash a lever.
    login_by_origin: {10, :timer.minutes(1)},
    # And per account, because the origin of a credential-stuffing run is not
    # stable but the account it targets is.
    login_by_account: {5, :timer.minutes(5)},
    # Renewal is a background call a client makes every quarter of an hour.
    refresh_by_origin: {30, :timer.minutes(1)},
    # Each one of these is an email. The reply is the same either way, so the
    # limit must not depend on whether the address exists.
    password_reset_by_origin: {5, :timer.hours(1)},
    password_reset_by_account: {3, :timer.hours(1)},
    # Codes are short. Guessing them should cost more than it yields, without
    # troubling a person typing the code from a projector twice.
    join_by_origin: {20, :timer.minutes(1)},
    # Per participation, never per room: one participant holding the mouse down
    # must not be able to make the room slow for everybody else.
    answer_by_participation: {30, :timer.minutes(1)}
  }

  @type bucket ::
          :login_by_origin
          | :login_by_account
          | :refresh_by_origin
          | :password_reset_by_origin
          | :password_reset_by_account
          | :join_by_origin
          | :answer_by_participation

  @doc "The budget of a bucket, as `{limit, window_in_milliseconds}`."
  @spec budget(bucket()) :: {pos_integer(), pos_integer()}
  def budget(bucket) when is_map_key(@budgets, bucket), do: Map.fetch!(@budgets, bucket)

  @doc "Every bucket that has a budget."
  @spec buckets() :: [bucket()]
  def buckets, do: Map.keys(@budgets)

  @doc "Tells whether budgets are enforced. They are not in `:test` by default."
  @spec enabled?() :: boolean()
  def enabled? do
    :live_quiz
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  @doc """
  Spends one attempt of `key` against the budget of `bucket`.

  Answers `:ok` while there is budget left, and `{:error, retry_after}` once
  there is not — `retry_after` being the whole seconds until the window turns
  over, which is what a `Retry-After` header is supposed to say.

  Spending happens on the way in, before the expensive thing, which is the
  point: a refused login must not cost a hash.

  `now` is the clock, in milliseconds, and exists so a test can cross a window
  without waiting an hour for it.
  """
  @spec hit(bucket(), term(), integer()) :: :ok | {:error, pos_integer()}
  def hit(bucket, key, now \\ System.system_time(:millisecond))

  def hit(bucket, key, now) when is_map_key(@budgets, bucket) do
    if enabled?() do
      count(bucket, key, now)
    else
      :ok
    end
  end

  @doc """
  Reads the state of a budget without spending it.

  For a caller that has already been refused once and only wants to say when to
  come back.
  """
  @spec peek(bucket(), term(), integer()) :: :ok | {:error, pos_integer()}
  def peek(bucket, key, now \\ System.system_time(:millisecond))

  def peek(bucket, key, now) when is_map_key(@budgets, bucket) do
    {limit, window} = Map.fetch!(@budgets, bucket)
    slot = div(now, window)

    case :ets.lookup(@table, {bucket, key, slot}) do
      [{_key, spent}] when spent >= limit -> {:error, retry_after(now, window, slot)}
      _within_budget -> :ok
    end
  end

  @doc """
  Deletes the rows of every window that is over.

  A row belongs to the window its slot names, and every slot below the current
  one is over. Matching on the slot keeps the sweep proportional to what is
  stale rather than to what is stored.

  Called on a timer, and callable directly by a test that wants to watch it
  work rather than wait for it.
  """
  @spec sweep(integer()) :: :ok
  def sweep(now \\ System.system_time(:millisecond)) do
    for {bucket, {_limit, window}} <- @budgets do
      :ets.select_delete(@table, [
        {{{bucket, :"$1", :"$2"}, :_}, [{:<, :"$2", div(now, window)}], [true]}
      ])
    end

    :ok
  end

  @doc "How many rows are held right now. The cardinality this module bounds."
  @spec size() :: non_neg_integer()
  def size, do: :ets.info(@table, :size)

  @doc "Forgets every count. For tests, which need a clean budget per case."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    # `:public` so counting happens in the caller: a limiter that funnels every
    # request through one process is a queue in front of the thing it protects.
    # The process owns the table and sweeps it, and nothing else.
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, schedule_sweep(%{})}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    sweep(System.system_time(:millisecond))

    {:noreply, schedule_sweep(state)}
  end

  defp schedule_sweep(state) do
    Process.send_after(self(), :sweep, @sweep_every)

    state
  end

  defp count(bucket, key, now) do
    {limit, window} = Map.fetch!(@budgets, bucket)
    slot = div(now, window)

    if overflowed?(bucket) do
      :ok
    else
      spent = :ets.update_counter(@table, {bucket, key, slot}, {2, 1}, {{bucket, key, slot}, 0})

      if spent > limit do
        refuse(bucket, retry_after(now, window, slot))
      else
        :ok
      end
    end
  end

  # Checked before writing, so the table cannot grow past the cap by being
  # asked about a key it does not hold yet.
  defp overflowed?(bucket) do
    if size() >= @max_rows do
      :telemetry.execute([:live_quiz, :rate_limit, :overflow], %{count: 1}, %{bucket: bucket})

      true
    else
      false
    end
  end

  defp refuse(bucket, retry_after) do
    :telemetry.execute([:live_quiz, :rate_limit, :refused], %{count: 1}, %{bucket: bucket})

    {:error, retry_after}
  end

  # Whole seconds, and never zero: `Retry-After: 0` invites the retry that was
  # just refused.
  defp retry_after(now, window, slot) do
    remaining = (slot + 1) * window - now

    max(div(remaining + 999, 1000), 1)
  end
end
