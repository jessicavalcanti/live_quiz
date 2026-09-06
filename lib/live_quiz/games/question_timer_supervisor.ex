defmodule LiveQuiz.Games.QuestionTimerSupervisor do
  @moduledoc """
  Supervises the question timers and puts the deadlines back after a restart.

  A `DynamicSupervisor` because timers come and go with the questions, paired
  with `LiveQuiz.Games.QuestionTimerRegistry` so a match has at most one of
  them and it can be found again to be stopped. Timers are `restart:
  :temporary`: a timer that dies is not a match that has to be revived — the
  deadline is in the database and the boot sweep will find it.

  `recover/0` is the whole restart story. It is not a rehydration of every
  match: the application only has to settle what the outage left pending. A
  question whose deadline ran out while the application was down is closed at
  once, with no extra time, and one still inside its deadline gets a timer armed
  with what is **left** of it and never with the full duration (AD-39). Matches
  that are already over are not listed in the first place.

  One match failing does not take the sweep down: the failure is logged and the
  rest is still processed, exactly like the `LiveQuiz.Games.ExpirationSweeper`.

  It runs from `LiveQuiz.Application.start/2`, right after the tree is up and
  before anything can connect, so no subscriber hears the broadcasts it
  produces. That is expected: the first `mount` reads the state from the
  database anyway. In `:test` it does not run at all — a sweep of a shared
  database at the start of every test would be a fine way to lose a suite.

  ## Test seam

  `recover/1` takes the source of the matches to settle, which is how a test
  feeds the sweep a match that blows up. The application always calls
  `recover/0`.
  """

  use DynamicSupervisor

  require Logger

  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.QuestionTimer

  @empty %{closed: 0, scheduled: 0}

  @doc "Starts the supervisor of the question timers."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Starts the timer of a match under this supervisor.

  Answers `{:error, {:already_started, pid}}` when the match already has one,
  which is what `LiveQuiz.Games.QuestionTimer.ensure_started/1` turns into a
  re-arming. `opts` are handed to the timer; only the tests use them, to get a
  deadline that fires on its own while the suite has scheduling switched off.
  """
  @spec start_timer(GameSession.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_timer(%GameSession{} = session, opts \\ []) do
    DynamicSupervisor.start_child(__MODULE__, {QuestionTimer, [{:session, session} | opts]})
  end

  @doc "Stops one timer. `{:error, :not_found}` when it is already gone."
  @spec stop_timer(pid()) :: :ok | {:error, :not_found}
  def stop_timer(pid) when is_pid(pid), do: DynamicSupervisor.terminate_child(__MODULE__, pid)

  @doc """
  Settles every match left with a question open and answers what it did.

  Overdue questions are closed right away — the outage buys nobody a second —
  and the ones still running get a timer for the time remaining.
  """
  @spec recover() :: %{closed: non_neg_integer(), scheduled: non_neg_integer()}
  @spec recover((-> [GameSession.t()])) :: %{
          closed: non_neg_integer(),
          scheduled: non_neg_integer()
        }
  def recover(lister \\ &Games.list_sessions_with_open_question/0) do
    lister.() |> Enum.reduce(@empty, &settle/2)
  rescue
    error -> log_failure("listing the matches with an open question", error, __STACKTRACE__)
  end

  defp settle(%GameSession{} = session, acc) do
    if due?(session), do: close(session, acc), else: rearm(session, acc)
  rescue
    error -> log_failure("recovering match #{inspect(session.id)}", error, __STACKTRACE__, acc)
  end

  defp close(%GameSession{id: id}, acc) do
    case Games.close_question_by_timeout(id) do
      {:ok, _closed} -> Map.update!(acc, :closed, &(&1 + 1))
      {:error, _reason} -> acc
    end
  end

  defp rearm(%GameSession{} = session, acc) do
    case QuestionTimer.ensure_started(session) do
      {:ok, _pid} -> Map.update!(acc, :scheduled, &(&1 + 1))
      {:error, _reason} -> acc
    end
  end

  defp due?(%GameSession{current_question_ends_at: nil}), do: false

  defp due?(%GameSession{current_question_ends_at: ends_at}) do
    DateTime.compare(DateTime.utc_now(), ends_at) != :lt
  end

  defp log_failure(what, error, stacktrace, acc \\ @empty) do
    Logger.error(
      "question timer recovery failed #{what}: " <>
        Exception.format(:error, error, stacktrace)
    )

    acc
  end
end
