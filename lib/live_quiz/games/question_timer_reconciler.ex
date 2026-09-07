defmodule LiveQuiz.Games.QuestionTimerReconciler do
  @moduledoc """
  Puts back the deadlines the application lost while it was running.

  Timers are `restart: :temporary` and some error paths end the process on
  purpose: a timer for a question that is over must not come back. The cost of
  that choice was that a timer lost to a crash, a transient database error or a
  restart of the registry came back only at the next boot — the application
  went on serving a match with a question open, no schedule behind it and
  nothing saying so (R19).

  Boot recovery was already handled by
  `LiveQuiz.Games.QuestionTimerSupervisor.recover/0`. This is the same work made
  periodic, which is what turns "until somebody restarts it" into "within one
  tick". It settles what it finds: an overdue question is closed at once — the
  delay buys nobody a second — and a question still running whose timer is
  missing gets one armed for what is **left** of its deadline.

  Reconciling is deliberately cheap to repeat. `QuestionTimer.ensure_started/1`
  is idempotent, so a question that already has its timer is re-armed for the
  same instant rather than duplicated, and closing is idempotent too. That is
  what makes a tick safe to run over a match that needs nothing.

  A match that fails does not take the tick down: the failure is logged, the
  remaining matches are still settled, and the next tick tries again — a
  transient database error is exactly the case this exists for.

  Like the sweeper, in `:test` the periodic tick is off and a reconciliation is
  triggered by hand with `reconcile_now/0`.
  """

  use GenServer

  require Logger

  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.QuestionTimer

  @tick :timer.seconds(15)

  @doc """
  Starts the reconciler.

  `:tick` overrides the interval in milliseconds, `:enabled` switches the
  periodic run off, `:lister` replaces the source of matches and `:name` the
  registered name — the last two only ever given by tests, which run a
  reconciler of their own by passing `name: nil`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.pop(opts, :name, __MODULE__) do
      {nil, opts} -> GenServer.start_link(__MODULE__, opts)
      {name, opts} -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Reconciles right away and answers with what it settled.

  `%{closed: n, armed: n}` — how many overdue questions were closed and how
  many running ones were missing a timer. A match that needed nothing counts in
  neither.
  """
  @spec reconcile_now(GenServer.server()) :: %{
          closed: non_neg_integer(),
          armed: non_neg_integer()
        }
  def reconcile_now(server \\ __MODULE__), do: GenServer.call(server, :reconcile)

  @doc "The interval between two reconciliations, in milliseconds."
  @spec tick() :: pos_integer()
  def tick, do: config(:tick, @tick)

  @doc "Tells whether the periodic reconciliation is on. It is off in `:test`."
  @spec enabled?() :: boolean()
  def enabled?, do: config(:enabled, true)

  @impl GenServer
  def init(opts) do
    state = %{
      tick: Keyword.get(opts, :tick, tick()),
      enabled: Keyword.get(opts, :enabled, enabled?()),
      lister: Keyword.get(opts, :lister, &Games.list_sessions_with_open_question/0)
    }

    schedule(state)

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:reconcile, _from, state), do: {:reply, reconcile(state), state}

  @impl GenServer
  def handle_info(:reconcile, state) do
    reconcile(state)
    schedule(state)

    {:noreply, state}
  end

  defp schedule(%{enabled: true, tick: tick}), do: Process.send_after(self(), :reconcile, tick)
  defp schedule(%{enabled: false}), do: :ok

  defp reconcile(%{lister: lister}) do
    lister.() |> Enum.reduce(%{closed: 0, armed: 0}, &settle/2)
  rescue
    error -> log_failure("listing the matches with an open question", error, __STACKTRACE__)
  end

  # The listing names candidates; the row decides. Between the two the host may
  # have closed the question, the last answer may have closed it, or the match
  # may have ended — and acting on the listing would count those as work this
  # tick did, making a quiet pass indistinguishable from a repair.
  defp settle(%GameSession{id: id} = session, acc) do
    case Games.get_live_game_session(id) do
      nil -> acc
      current -> settle_current(current, acc)
    end
  rescue
    error -> log_failure("reconciling match #{inspect(session.id)}", error, __STACKTRACE__, acc)
  end

  defp settle_current(%GameSession{} = session, acc) do
    cond do
      not GameSession.question_open?(session) -> acc
      GameSession.question_due?(session) -> close(session, acc)
      is_nil(QuestionTimer.whereis(session.id)) -> arm(session, acc)
      # It has a timer and time on the clock. Nothing to settle, and re-arming
      # every live match on every tick would be work for no reason.
      true -> acc
    end
  end

  defp close(%GameSession{id: id, current_question_position: position}, acc) do
    case Games.close_question_by_timeout(id, position) do
      {:ok, _closed} -> Map.update!(acc, :closed, &(&1 + 1))
      {:error, reason} -> already_settled("close", id, reason, acc)
    end
  end

  defp arm(%GameSession{id: id} = session, acc) do
    case QuestionTimer.ensure_started(session) do
      {:ok, _pid} ->
        Logger.info("reconciler re-armed the timer of match #{inspect(id)}")
        Map.update!(acc, :armed, &(&1 + 1))

      {:error, reason} ->
        already_settled("arm the timer of", id, reason, acc)
    end
  end

  # The row moved between the listing and this call — another timer, the host or
  # the last answer settled it first. That is the ordinary outcome of
  # reconciling alongside a healthy match, so it is noted and not counted:
  # reporting it as work done would make a quiet tick look like a repair.
  defp already_settled(what, id, reason, acc) do
    Logger.debug("reconciler did not #{what} match #{inspect(id)}: #{inspect(reason)}")

    acc
  end

  defp config(key, default) do
    :live_quiz
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp log_failure(what, error, stacktrace, acc \\ %{closed: 0, armed: 0}) do
    Logger.error(
      "question timer reconciliation failed #{what}: " <>
        Exception.format(:error, error, stacktrace)
    )

    acc
  end
end
