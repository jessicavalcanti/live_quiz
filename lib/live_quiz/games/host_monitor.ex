defmodule LiveQuiz.Games.HostMonitor do
  @moduledoc """
  The grace period between the host dropping off and the room noticing it.

  A page reload takes the host presence down and puts it back in well under a
  second. Without a waiting window every refresh would start a five minute
  countdown and warn everybody in the lobby, so an absence only counts
  after ten continuous seconds — the window is configurable and nothing else
  here is timed.

  This process holds no rule and no deadline: it decides *when* to ask, and
  `LiveQuiz.Games` decides what that means and writes it down. The deadline
  itself lives in `expires_at`, in the database (AD-23).

  The pending window is cancelled when the host comes back, and the confirmation
  checks the presence once more before recording anything: cancelling a timer
  that already fired is a race, re-reading who is connected is not. Each window
  carries a reference of its own, and a confirmation only counts when it still
  matches the one registered: in a drop → return → drop sequence the message
  from the first window would otherwise arrive, find the host away again, apply
  the wrong grace and delete the entry the new window was waiting on (R21).

  ## Reconciliation

  A restart of this process used to forget every pending window and nothing put
  them back. If the absence had not been persisted yet, `expires_at` stayed
  null, the sweeper never found the room, and an abandoned room lived forever
  (R20). A periodic pass compares presence against the database and feeds the
  same two casts, so a room whose absence was lost gets a window like any other
  — including the grace, which is what keeps a host reconnecting right after a
  restart from losing the room.

  It only looks at rooms that **have** had a host connection. A room opened
  through the API and never claimed from a socket has no presence to compare
  against, and reading its empty presence as an absence would expire a room
  whose host is driving it over HTTP. What liveness means for those is a
  contract still to be defined — heartbeat, lease or expiry by activity — and
  this pass deliberately leaves them exactly as they were.

  ## Test seam

  `:host_monitor` in the `:live_quiz` application environment replaces the
  process `LiveQuiz.Games.Presence` notifies, which is how a test drives a
  monitor of its own — with its own grace period and its own timers — instead
  of the one the application supervises. It is unset everywhere but in those
  tests. `:tick` and `:enabled` do the same for the reconciliation, which is
  off in `:test` and driven by `reconcile_now/1`.
  """

  use GenServer

  require Logger

  alias LiveQuiz.Games
  alias LiveQuiz.Games.Presence
  alias LiveQuiz.Games.Telemetry

  @default_grace_period :timer.seconds(10)
  @default_tick :timer.seconds(30)

  @doc """
  Starts the monitor.

  `:grace_period` overrides the configured window, in milliseconds, and
  `:name` the registered name — both only ever given by tests, which run a
  monitor of their own by passing `name: nil`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.pop(opts, :name, __MODULE__) do
      {nil, opts} -> GenServer.start_link(__MODULE__, opts)
      {name, opts} -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Reports that the host of the room is connected again."
  @spec host_connected(integer(), GenServer.server()) :: :ok
  def host_connected(session_id, server \\ server()) do
    GenServer.cast(server, {:host_connected, session_id})
  end

  @doc "Reports that the host of the room has no connection left."
  @spec host_disconnected(integer(), GenServer.server()) :: :ok
  def host_disconnected(session_id, server \\ server()) do
    GenServer.cast(server, {:host_disconnected, session_id})
  end

  @doc "The process the presence reports to. See the test seam above."
  @spec server() :: GenServer.server()
  def server, do: Application.get_env(:live_quiz, :host_monitor, __MODULE__)

  @doc """
  Reconciles presence against the database right away and answers what it did.

  `%{opened: n, cleared: n}` — how many rooms had a grace window opened for a
  host that is gone and how many had a stale deadline dropped for a host that
  is here. This is how a test runs the pass without waiting for a tick; the
  application only ever ticks.
  """
  @spec reconcile_now(GenServer.server()) :: %{
          opened: non_neg_integer(),
          cleared: non_neg_integer()
        }
  def reconcile_now(server \\ server()), do: GenServer.call(server, :reconcile)

  @doc "How long the host may be away before the room reacts, in milliseconds."
  @spec grace_period() :: pos_integer()
  def grace_period, do: config(:grace_period, @default_grace_period)

  @doc "The interval between two reconciliations, in milliseconds."
  @spec tick() :: pos_integer()
  def tick, do: config(:tick, @default_tick)

  @doc "Tells whether the periodic reconciliation is on. It is off in `:test`."
  @spec enabled?() :: boolean()
  def enabled?, do: config(:enabled, true)

  defp config(key, default) do
    :live_quiz
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  @doc "The grace period used when nothing is configured, in milliseconds."
  @spec default_grace_period() :: pos_integer()
  def default_grace_period, do: @default_grace_period

  @impl GenServer
  def init(opts) do
    state = %{
      grace_period: Keyword.get(opts, :grace_period, grace_period()),
      tick: Keyword.get(opts, :tick, tick()),
      enabled: Keyword.get(opts, :enabled, enabled?()),
      lister: Keyword.get(opts, :lister, &Games.list_sessions_with_host_claim/0),
      pending: %{}
    }

    schedule(state)

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:host_disconnected, session_id}, state) do
    if Map.has_key?(state.pending, session_id) do
      {:noreply, state}
    else
      # The reference identifies this absence, not the room. Two windows for the
      # same room are two different absences, and only the message carrying the
      # reference of the one still registered may act on it (R21).
      cycle = make_ref()

      timer =
        Process.send_after(self(), {:confirm_absence, session_id, cycle}, state.grace_period)

      {:noreply, %{state | pending: Map.put(state.pending, session_id, {cycle, timer})}}
    end
  end

  def handle_cast({:host_connected, session_id}, state) do
    case Map.pop(state.pending, session_id) do
      # Coming back inside the window: nothing was ever recorded, so there is
      # nothing to undo and nothing to announce.
      {{_cycle, timer}, pending} when is_reference(timer) ->
        Process.cancel_timer(timer)
        {:noreply, %{state | pending: pending}}

      {nil, _pending} ->
        safely(session_id, fn -> Games.record_host_return(session_id) end)
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_call(:reconcile, _from, state), do: {:reply, reconcile(state), state}

  @impl GenServer
  def handle_info(:reconcile, state) do
    reconcile(state)
    schedule(state)

    {:noreply, state}
  end

  # Cancelling a timer does not unsend a message that is already in the mailbox.
  # Without the reference, a confirmation from a window that was cancelled would
  # find the host away again — a new absence, with its own deadline — apply the
  # older grace to it and delete the entry the new window is waiting on (R21).
  def handle_info({:confirm_absence, session_id, cycle}, state) do
    case Map.get(state.pending, session_id) do
      {^cycle, _timer} -> {:noreply, confirm_absence(session_id, state)}
      _other_cycle_or_none -> {:noreply, state}
    end
  end

  defp confirm_absence(session_id, state) do
    # Whether *the* host connection is here, not whether some host tab is. A tab
    # another device took the room from still holds a presence, and reading it
    # as the host being present kept an abandoned room from ever expiring (R22).
    #
    # Reading the room is inside the guard along with the write: it is a query
    # like any other, and a failure there must not take down the monitor
    # watching every other room either.
    safely(session_id, fn ->
      if host_in_control?(session_id) do
        :ok
      else
        Games.record_host_absence(session_id)
      end
    end)

    %{state | pending: Map.delete(state.pending, session_id)}
  end

  defp schedule(%{enabled: true, tick: tick}), do: Process.send_after(self(), :reconcile, tick)
  defp schedule(%{enabled: false}), do: :ok

  # Presence is memory and the deadline is a row; a restart of this process
  # loses the first and keeps the second, which is exactly how a room could end
  # up abandoned with no deadline behind it. The pass feeds the same two casts
  # rather than writing anything itself, so a room found without its host gets a
  # grace window like any other.
  defp reconcile(state) do
    Telemetry.reconciliation(:host_absence, fn -> sweep(state) end)
  end

  defp sweep(%{lister: lister} = state) do
    lister.() |> Enum.reduce(%{opened: 0, cleared: 0}, &reconcile_room(&1, &2, state))
  rescue
    error ->
      log_failure("listing the rooms to reconcile", error, __STACKTRACE__)
      %{opened: 0, cleared: 0}
  end

  # Nothing is written here: both branches go through the same casts a real
  # presence change goes through, so a room found without its host waits out the
  # grace exactly like one whose socket just dropped.
  defp reconcile_room(session, acc, state) do
    cond do
      Presence.host_in_control?(session) and not is_nil(session.expires_at) ->
        host_connected(session.id, self())
        Map.update!(acc, :cleared, &(&1 + 1))

      not Presence.host_in_control?(session) and is_nil(session.expires_at) and
          not Map.has_key?(state.pending, session.id) ->
        host_disconnected(session.id, self())
        Map.update!(acc, :opened, &(&1 + 1))

      true ->
        acc
    end
  end

  defp log_failure(what, error, stacktrace) do
    Logger.error(
      "host presence reconciliation failed #{what}: " <>
        Exception.format(:error, error, stacktrace)
    )

    :error
  end

  defp host_in_control?(session_id) do
    case Games.get_live_game_session(session_id) do
      nil -> false
      session -> Presence.host_in_control?(session)
    end
  end

  # A room the database refuses to update must not take the monitor down with
  # it: the other rooms it is watching have nothing to do with that failure,
  # and restarting would drop every grace window they are waiting on.
  defp safely(session_id, fun) do
    fun.()
  rescue
    error ->
      Logger.error(
        "host presence change for room #{session_id} failed: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :error
  end
end
