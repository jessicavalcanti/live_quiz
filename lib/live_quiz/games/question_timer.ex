defmodule LiveQuiz.Games.QuestionTimer do
  @moduledoc """
  The deadline of the question that is open, kept by the server.

  One process per match with a question open (AD-40), and not a periodic sweep
  like the `LiveQuiz.Games.ExpirationSweeper` of phase 2: a room survives its
  host being away for five minutes, so being ten seconds late to expire it is
  irrelevant, while a question that lasts ten seconds cannot be closed whenever
  the next tick happens to come around. F2-06 recorded that the decision would
  be revisited here, and this is where it is.

  The process holds almost nothing: the id of the match, the position it is
  timing and the instant that position ends at. **The deadline itself lives in
  `game_sessions.current_question_ends_at`** (AD-39), so losing this process
  loses no deadline — it only delays the closing until
  `LiveQuiz.Games.QuestionTimerSupervisor.recover/0` runs on the next boot.
  That is a degradation; forgetting the deadline would not be.

  Waking up is a single `Process.send_after/3` for the interval up to `ends_at`,
  not a tick: one message per question buys the precision the countdown people
  watch is worth. When it arrives the match is **read back from the database**
  and the position is compared with the one this timer was armed for, which is
  what stops a message scheduled for question 1 and delivered after the host
  advanced from closing question 2. That comparison is the point of the design,
  not a defensive extra.

  Closing goes through `LiveQuiz.Games.close_question_by_timeout/1`, which takes
  no scope — the caller is the system, exactly like `expire_game_session/1` —
  and is idempotent. That is what makes the meeting of the three ways a question
  can end (the deadline, the host, everybody having answered) a race with one
  winner and one `{:question_closed, session}` instead of a double reveal.

  The `Registry` is local to the node. With more than one node each would keep
  its own timer for the same match and both would fire; the idempotence covers
  the effect, and the observation is the same one F2-06 left about the sweeper.

  ## Test seam

  `:enabled` in the `LiveQuiz.Games.QuestionTimer` key of the `:live_quiz`
  application environment switches the scheduling off, the way `:enabled` does
  for the sweeper. With it off the process is still started, registered and
  stopped as usual, but it never arms `Process.send_after/3`: nothing fires by
  itself and a test drives the deadline with `fire_now/1`. It is `false` only
  in `:test`.
  """

  use GenServer, restart: :temporary

  require Logger

  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.QuestionTimerSupervisor

  @registry LiveQuiz.Games.QuestionTimerRegistry

  @doc """
  Makes sure the match has a timer armed for the deadline it currently holds.

  Idempotent by design: the `Registry` allows a single timer per match, so
  calling this again — which is what every advance does — re-arms the timer
  that already exists for the new position instead of adding a second one.

  A match with no question taking answers has no deadline to keep and answers
  `{:error, :no_open_question}`.
  """
  @spec ensure_started(GameSession.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(%GameSession{} = session) do
    if armable?(session) do
      start_or_rearm(session, 2)
    else
      {:error, :no_open_question}
    end
  end

  @doc """
  Stops the timer of the match, if it has one.

  Always `:ok`: a match that never had a timer, or whose timer has already
  fired and terminated, is not an error — it is the ordinary state of a match
  between two questions.

  Calling it from inside the timer itself is a no-op, so the process that just
  closed a question by the deadline never waits on its own shutdown.
  """
  @spec stop(integer()) :: :ok
  def stop(session_id) when is_integer(session_id) do
    case whereis(session_id) do
      nil -> :ok
      pid when pid == self() -> :ok
      pid -> terminate(pid)
    end
  end

  @doc "The live timer of the match, or `nil`. Used by the tests and by `stop/1`."
  @spec whereis(integer()) :: pid() | nil
  def whereis(session_id) when is_integer(session_id) do
    case Registry.lookup(@registry, key(session_id)) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc """
  Runs the deadline check right away, without waiting for the scheduled message.

  This is how a test reaches the closing without sleeping through a real
  deadline; the application itself never calls it.
  """
  @spec fire_now(integer()) :: :ok | {:error, :not_found}
  def fire_now(session_id) when is_integer(session_id) do
    case whereis(session_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :check)
    end
  end

  @doc "Tells whether timers arm themselves. They do not in `:test`."
  @spec enabled?() :: boolean()
  def enabled? do
    :live_quiz
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  @doc """
  Starts a timer for the match given in `:session`.

  Started through `LiveQuiz.Games.QuestionTimerSupervisor` rather than directly;
  `:enabled` overrides the configured scheduling and is only ever given by the
  tests that want a deadline to fire on its own.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session = Keyword.fetch!(opts, :session)

    GenServer.start_link(__MODULE__, opts, name: via(session.id))
  end

  @impl GenServer
  def init(opts) do
    %GameSession{} = session = Keyword.fetch!(opts, :session)

    # Trapping exits is what makes `terminate/2` — and with it the unregistering
    # below — run when the supervisor stops this timer. Without it the process
    # would die at once and the `Registry` would only notice later, leaving
    # `whereis/1` answering with a pid that is already gone and the next advance
    # racing an entry nobody owns.
    Process.flag(:trap_exit, true)

    state = %{
      session_id: session.id,
      position: session.current_question_position,
      ends_at: session.current_question_ends_at,
      enabled: Keyword.get(opts, :enabled, enabled?()),
      timer: nil
    }

    {:ok, schedule(state)}
  end

  @impl GenServer
  def handle_call({:rearm, position, ends_at}, _from, state) do
    {:reply, :ok, schedule(%{state | position: position, ends_at: ends_at})}
  end

  def handle_call(:check, _from, state) do
    case check(state) do
      :done -> {:stop, :normal, :ok, state}
      {:wait, state} -> {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_info(:check, state) do
    case check(state) do
      :done -> {:stop, :normal, state}
      {:wait, state} -> {:noreply, state}
    end
  end

  # Giving the key back here rather than letting the `Registry` collect it from
  # the `:DOWN` message is what makes a match free for a new timer the instant
  # the old one is gone.
  @impl GenServer
  def terminate(_reason, state) do
    Registry.unregister(@registry, key(state.session_id))

    :ok
  end

  # A match still open on the position this timer was armed for, and already
  # past its deadline, is the only case that closes anything. Every other one
  # ends the process: the question is closed, the match is over, or the timer is
  # late for a question that is no longer the current one.
  defp check(state) do
    case Games.get_session_for_timeout(state.session_id) do
      {:error, :not_found} -> :done
      {:ok, session} -> act_on(state, session)
    end
  rescue
    error ->
      Logger.error(
        "question timer failed reading match #{inspect(state.session_id)}: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :done
  end

  defp act_on(state, %GameSession{} = session) do
    cond do
      not GameSession.question_open?(session) -> :done
      session.current_question_position != state.position -> :done
      GameSession.question_due?(session) -> close(state)
      true -> {:wait, schedule(%{state | ends_at: session.current_question_ends_at})}
    end
  end

  defp close(state) do
    Games.close_question_by_timeout(state.session_id)

    :done
  rescue
    error ->
      Logger.error(
        "question timer failed closing match #{inspect(state.session_id)}: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :done
  end

  # A deadline already in the past becomes `0` instead of a negative interval,
  # which `Process.send_after/3` refuses.
  defp schedule(%{enabled: false} = state), do: cancel(state)

  defp schedule(state) do
    state = cancel(state)

    %{state | timer: Process.send_after(self(), :check, remaining(state.ends_at))}
  end

  defp cancel(%{timer: nil} = state), do: state

  defp cancel(%{timer: timer} = state) do
    Process.cancel_timer(timer)

    %{state | timer: nil}
  end

  defp remaining(nil), do: 0

  defp remaining(ends_at) do
    ends_at |> DateTime.diff(DateTime.utc_now(), :millisecond) |> max(0)
  end

  defp armable?(%GameSession{} = session) do
    GameSession.question_open?(session) and not is_nil(session.current_question_ends_at)
  end

  # The timer that lost its race to a shutdown between the lookup and the call
  # is started again rather than reported: the caller asked for a timer, not for
  # a particular process.
  defp start_or_rearm(%GameSession{}, 0), do: {:error, :timer_unavailable}

  defp start_or_rearm(%GameSession{} = session, attempts_left) do
    case QuestionTimerSupervisor.start_timer(session) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> rearm(pid, session, attempts_left)
      {:error, reason} -> {:error, reason}
    end
  end

  defp rearm(pid, %GameSession{} = session, attempts_left) do
    GenServer.call(
      pid,
      {:rearm, session.current_question_position, session.current_question_ends_at}
    )

    {:ok, pid}
  catch
    :exit, _reason ->
      await_down(pid)
      start_or_rearm(session, attempts_left - 1)
  end

  defp await_down(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      100 ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end

  defp terminate(pid) do
    QuestionTimerSupervisor.stop_timer(pid)

    :ok
  end

  defp via(session_id), do: {:via, Registry, {@registry, key(session_id)}}

  defp key(session_id), do: {:question_timer, session_id}
end
