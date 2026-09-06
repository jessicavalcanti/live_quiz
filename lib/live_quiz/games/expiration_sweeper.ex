defmodule LiveQuiz.Games.ExpirationSweeper do
  @moduledoc """
  Closes the rooms whose host stayed away past the deadline.

  One process for the whole application, waking every ten seconds, instead of
  one timer per room (AD-23): the deadline is five minutes long, so being up to
  a tick late is irrelevant, and a room needs neither a process nor a
  rehydration step to be expired. **A room may therefore be expired up to ten
  seconds after its deadline — that is the design, not a defect.**

  Because the deadline lives in `expires_at` and not in a timer, recovering
  after a restart is not a special code path: the first sweep after boot finds
  every deadline that ran out while the application was down and applies it
  without granting a single extra second. Rooms that were already closed are
  never picked up — `list_expired_sessions/1` only answers with live ones.

  A room that fails to close does not take the sweep down with it: the failure
  is logged and the remaining rooms are still processed. `expire_game_session/1`
  is idempotent, which is also what keeps a sweeper running on every node of a
  cluster from closing a room twice — worth revisiting when there is more than
  one node.

  In `:test` the periodic tick is switched off and the sweep is triggered by
  hand with `sweep_now/0`.
  """

  use GenServer

  require Logger

  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession

  @tick :timer.seconds(10)

  @doc """
  Starts the sweeper.

  `:tick` overrides the interval in milliseconds, `:enabled` switches the
  periodic sweep off, `:lister` replaces the source of expired rooms and
  `:name` the registered name — the last two only ever given by tests, which
  run a sweeper of their own by passing `name: nil`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.pop(opts, :name, __MODULE__) do
      {nil, opts} -> GenServer.start_link(__MODULE__, opts)
      {name, opts} -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Runs a sweep right away and answers with the rooms it closed.

  This is how tests advance time without waiting for a tick; the application
  itself never calls it.
  """
  @spec sweep_now(GenServer.server()) :: [GameSession.t()]
  def sweep_now(server \\ __MODULE__), do: GenServer.call(server, :sweep)

  @doc "The interval between two sweeps, in milliseconds."
  @spec tick() :: pos_integer()
  def tick, do: config(:tick, @tick)

  @doc "Tells whether the periodic sweep is on. It is off in `:test`."
  @spec enabled?() :: boolean()
  def enabled?, do: config(:enabled, true)

  @impl GenServer
  def init(opts) do
    state = %{
      tick: Keyword.get(opts, :tick, tick()),
      enabled: Keyword.get(opts, :enabled, enabled?()),
      lister: Keyword.get(opts, :lister, &Games.list_expired_sessions/0)
    }

    schedule(state)

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:sweep, _from, state), do: {:reply, sweep(state), state}

  @impl GenServer
  def handle_info(:sweep, state) do
    sweep(state)
    schedule(state)

    {:noreply, state}
  end

  defp schedule(%{enabled: true, tick: tick}), do: Process.send_after(self(), :sweep, tick)
  defp schedule(%{enabled: false}), do: :ok

  defp sweep(%{lister: lister}) do
    lister.() |> Enum.flat_map(&expire/1)
  rescue
    error -> log_failure("listing the expired rooms", error, __STACKTRACE__)
  end

  defp expire(%GameSession{} = session) do
    case Games.expire_game_session(session) do
      {:ok, session} -> [session]
      {:error, :invalid_transition} -> []
    end
  rescue
    error -> log_failure("expiring room #{inspect(session.id)}", error, __STACKTRACE__)
  end

  defp config(key, default) do
    :live_quiz
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp log_failure(what, error, stacktrace) do
    Logger.error("sweeper failed #{what}: " <> Exception.format(:error, error, stacktrace))

    []
  end
end
