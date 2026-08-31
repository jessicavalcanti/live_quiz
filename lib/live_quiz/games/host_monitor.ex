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
  itself lives in `expires_at`, in the database (AD-23), so a restart of this
  process forgets a pending grace window and nothing else — the host is either
  back, and the next connection clears the deadline, or gone, and the next
  absence opens a new window.

  The pending window is cancelled when the host comes back, and the confirmation
  checks the presence once more before recording anything: cancelling a timer
  that already fired is a race, re-reading who is connected is not.

  ## Test seam

  `:host_monitor` in the `:live_quiz` application environment replaces the
  process `LiveQuiz.Games.Presence` notifies, which is how a test drives a
  monitor of its own — with its own grace period and its own timers — instead
  of the one the application supervises. It is unset everywhere but in those
  tests.
  """

  use GenServer

  require Logger

  alias LiveQuiz.Games
  alias LiveQuiz.Games.Presence

  @default_grace_period :timer.seconds(10)

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

  @doc "How long the host may be away before the room reacts, in milliseconds."
  @spec grace_period() :: pos_integer()
  def grace_period do
    :live_quiz
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:grace_period, @default_grace_period)
  end

  @doc "The grace period used when nothing is configured, in milliseconds."
  @spec default_grace_period() :: pos_integer()
  def default_grace_period, do: @default_grace_period

  @impl GenServer
  def init(opts) do
    {:ok, %{grace_period: Keyword.get(opts, :grace_period, grace_period()), pending: %{}}}
  end

  @impl GenServer
  def handle_cast({:host_disconnected, session_id}, state) do
    if Map.has_key?(state.pending, session_id) do
      {:noreply, state}
    else
      timer = Process.send_after(self(), {:confirm_absence, session_id}, state.grace_period)
      {:noreply, %{state | pending: Map.put(state.pending, session_id, timer)}}
    end
  end

  def handle_cast({:host_connected, session_id}, state) do
    case Map.pop(state.pending, session_id) do
      # Coming back inside the window: nothing was ever recorded, so there is
      # nothing to undo and nothing to announce.
      {timer, pending} when is_reference(timer) ->
        Process.cancel_timer(timer)
        {:noreply, %{state | pending: pending}}

      {nil, _pending} ->
        safely(session_id, fn -> Games.record_host_return(session_id) end)
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:confirm_absence, session_id}, state) do
    if Presence.host_connected?(session_id) do
      :ok
    else
      safely(session_id, fn -> Games.record_host_absence(session_id) end)
    end

    {:noreply, %{state | pending: Map.delete(state.pending, session_id)}}
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
