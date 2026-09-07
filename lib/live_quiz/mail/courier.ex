defmodule LiveQuiz.Mail.Courier do
  @moduledoc """
  Drains the outbox, on a timer and whenever somebody records a message.

  A timer alone would make every message wait up to a tick; a nudge alone would
  lose whatever was recorded while the process was down, or whatever failed and
  is waiting out its backoff. Both, and the timer is the one that matters —
  the nudge only makes the common case immediate.

  Sending never happens inside the caller's request. That is the whole point of
  `LiveQuiz.Mail`: a provider that is slow must not make the interface slow
  (R07).
  """

  use GenServer

  alias LiveQuiz.Mail

  require Logger

  @tick :timer.seconds(15)

  @doc "Asks for a drain now, without waiting for the tick."
  @spec nudge() :: :ok
  def nudge, do: GenServer.cast(__MODULE__, :drain)

  @doc "Drains and answers how many were sent. For tests that want to be sure."
  @spec drain_now() :: non_neg_integer()
  def drain_now, do: GenServer.call(__MODULE__, :drain)

  @doc false
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    {:ok, schedule(%{enabled: Keyword.get(opts, :enabled, enabled?())})}
  end

  @doc "Tells whether the courier drains on its own. It does not in `:test`."
  @spec enabled?() :: boolean()
  def enabled? do
    :live_quiz
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  @impl GenServer
  def handle_cast(:drain, state) do
    drain()

    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:drain, _from, state) do
    {:reply, drain(), state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    if state.enabled, do: drain()

    {:noreply, schedule(state)}
  end

  defp schedule(state) do
    Process.send_after(self(), :tick, @tick)

    state
  end

  # A provider that raises must not take the courier with it: the row is still
  # there, its attempt is spent, and the next tick tries again.
  defp drain do
    Mail.drain()
  rescue
    error ->
      Logger.error("the mail courier failed a pass: #{Exception.message(error)}")

      0
  end
end
