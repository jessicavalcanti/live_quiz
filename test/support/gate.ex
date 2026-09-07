defmodule LiveQuiz.Gate do
  @moduledoc """
  A rendezvous the test drives by hand, so a race runs in the order it wants.

  `Process.sleep/1` is the alternative and it is not one: it makes a fast
  machine pass a test a slow machine fails, and it never proves the
  interleaving actually happened. Here a competitor stops at a named point and
  stays there until the test says otherwise, so the order under test is the
  order that ran — every time, at any speed.

      gate = Gate.start!()

      task = Task.async(fn ->
        session = read_session()
        Gate.pause(gate, :read_done)
        write_using(session)
      end)

      Gate.await_paused(gate, :read_done)
      finish_the_session_from_here()
      Gate.release(gate, :read_done)

      Task.await(task)

  `await_paused/3` is what makes it deterministic: the test does not continue
  until the competitor is really stopped at the point, so "I got there first"
  is a fact rather than a hope.
  """

  use GenServer

  @timeout 10_000

  @doc "Starts a gate that is stopped when the test ends."
  @spec start!() :: pid()
  def start! do
    {:ok, pid} = GenServer.start_link(__MODULE__, :ok)
    pid
  end

  @doc """
  Stops the calling process at `point` until the test releases it.

  Returns `:ok` once released, and raises if nobody releases it in time — a
  hung competitor should fail the test, not the whole run.
  """
  @spec pause(pid(), atom(), timeout()) :: :ok
  def pause(gate, point, timeout \\ @timeout) do
    GenServer.call(gate, {:pause, point}, timeout)
  end

  @doc "Blocks until some process is stopped at `point`."
  @spec await_paused(pid(), atom(), timeout()) :: :ok
  def await_paused(gate, point, timeout \\ @timeout) do
    GenServer.call(gate, {:await_paused, point}, timeout)
  end

  @doc "Lets whoever is stopped at `point` carry on."
  @spec release(pid(), atom()) :: :ok
  def release(gate, point) do
    GenServer.call(gate, {:release, point})
  end

  @impl true
  def init(:ok), do: {:ok, %{paused: %{}, waiting: %{}}}

  @impl true
  def handle_call({:pause, point}, from, state) do
    state = %{state | paused: Map.put(state.paused, point, from)}

    case Map.pop(state.waiting, point) do
      {nil, _waiting} ->
        {:noreply, state}

      {watcher, waiting} ->
        GenServer.reply(watcher, :ok)
        {:noreply, %{state | waiting: waiting}}
    end
  end

  def handle_call({:await_paused, point}, from, state) do
    if Map.has_key?(state.paused, point) do
      {:reply, :ok, state}
    else
      {:noreply, %{state | waiting: Map.put(state.waiting, point, from)}}
    end
  end

  def handle_call({:release, point}, _from, state) do
    case Map.pop(state.paused, point) do
      {nil, _paused} ->
        {:reply, :ok, state}

      {competitor, paused} ->
        GenServer.reply(competitor, :ok)
        {:reply, :ok, %{state | paused: paused}}
    end
  end
end
