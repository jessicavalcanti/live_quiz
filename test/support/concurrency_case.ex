defmodule LiveQuiz.ConcurrencyCase do
  @moduledoc """
  The setup for tests that have to prove a race, not merely describe one.

  `LiveQuiz.DataCase` lends every process the *same* checked-out connection, so
  tasks started inside a test take turns on one transaction. That is enough to
  test what happens between processes, and it is exactly wrong for testing what
  happens between transactions: an advisory lock taken twice on one connection
  never blocks, and a competitor never sees a row another competitor committed,
  because there is no other commit to see.

  Here the sandbox runs in `:auto` mode instead. Every process checks out its
  own connection, which is its own PostgreSQL backend, so locks really block
  and commits really become visible. `assert_distinct_backends/1` is available
  to say so in the test rather than assume it.

  The price is that nothing is rolled back for you. The tables are truncated
  after each test, which is why these cases are `async: false`: they must not
  run while another test holds rows they are about to delete. ExUnit runs every
  async module before the sync ones, so that ordering comes for free.

      use LiveQuiz.ConcurrencyCase

      test "only one of them takes the last seat" do
        results = compete([fn -> join(...) end, fn -> join(...) end])
        assert Enum.count(results, &match?({:ok, _, _}, &1)) == 1
      end

  Use `LiveQuiz.Gate` when the race needs a specific order instead of a
  simultaneous start.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias LiveQuiz.Gate
  alias LiveQuiz.Repo

  # Truncated child-first, though CASCADE would cover it; the explicit order is
  # here so a new table shows up as a missing name rather than as silent data
  # left behind for the next test.
  @tables ~w(
    answers
    game_results
    game_session_answer_options
    game_session_questions
    participants
    game_sessions
    answer_options
    questions
    quizzes
    users_tokens
    users
  )

  using do
    quote do
      alias LiveQuiz.Gate
      alias LiveQuiz.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import LiveQuiz.ConcurrencyCase
      import LiveQuiz.DataCase, only: [errors_on: 1]

      @moduletag :concurrency
    end
  end

  setup tags do
    if tags[:async] do
      raise ArgumentError,
            "#{inspect(tags[:module])} must be `async: false`: it truncates the tables it shares"
    end

    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      truncate_all()
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  @doc """
  Runs the functions at once, each on its own connection, and answers with
  their results in the order they were given.

  The start is synchronized: every competitor is up and holding a connection
  before any of them is let go, so the race begins as close to together as the
  runtime allows. When the interleaving has to be exact rather than
  simultaneous, drive it with `LiveQuiz.Gate` instead.
  """
  @spec compete([(-> term())], timeout()) :: [term()]
  def compete(funs, timeout \\ 30_000) when is_list(funs) do
    ensure_pool_fits(length(funs))

    gate = Gate.start!()
    point = fn index -> :"competitor_#{index}" end

    tasks =
      funs
      |> Enum.with_index()
      |> Enum.map(fn {fun, index} ->
        Task.async(fn ->
          Gate.pause(gate, point.(index))
          fun.()
        end)
      end)

    for index <- 0..(length(funs) - 1), do: Gate.await_paused(gate, point.(index))
    for index <- 0..(length(funs) - 1), do: Gate.release(gate, point.(index))

    Task.await_many(tasks, timeout)
  end

  @doc """
  Asserts the given functions each run on a different PostgreSQL backend.

  The guard against a test that looks like a race and is not: under the shared
  sandbox connection this fails, which is the whole reason this case exists.
  """
  @spec assert_distinct_backends(pos_integer()) :: :ok
  def assert_distinct_backends(count \\ 2) when count > 1 do
    pids = compete(List.duplicate(&backend_pid/0, count))

    if length(Enum.uniq(pids)) == count do
      :ok
    else
      raise ExUnit.AssertionError,
        message:
          "expected #{count} distinct PostgreSQL backends, got #{inspect(Enum.uniq(pids))} — " <>
            "the competitors are sharing a connection and no lock between them can block"
    end
  end

  @doc """
  How many competitors this machine can actually race at once.

  Every competitor holds a connection for as long as its transaction lasts, so
  the pool is the ceiling — one connection is left over for the test process
  itself. The pool is sized from `System.schedulers_online/0`, which is why a
  number that fits a developer's laptop can be three too many on a CI runner:
  tests ask for this rather than for a number they picked.
  """
  @spec max_competitors() :: pos_integer()
  def max_competitors do
    Keyword.fetch!(Repo.config(), :pool_size) - 1
  end

  @doc "The pid of the PostgreSQL backend serving the calling process."
  @spec backend_pid() :: integer()
  def backend_pid do
    %Postgrex.Result{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  # Every competitor holds a connection for as long as its transaction lasts, so
  # a race wider than the pool does not race: the extra competitors queue on the
  # pool and time out. Saying that here turns a confusing DBConnection timeout
  # into the actual problem, which is that the test asked for too many.
  defp ensure_pool_fits(count) do
    if count > max_competitors() do
      raise ArgumentError,
            "#{count} competitors do not fit the pool of " <>
              "#{Keyword.fetch!(Repo.config(), :pool_size)} connections; a race only needs " <>
              "enough competitors to contend, not one per row — size it with max_competitors/0"
    end
  end

  @doc "Empties every table, so the next test starts from nothing."
  @spec truncate_all() :: :ok
  def truncate_all do
    Repo.query!("TRUNCATE TABLE #{Enum.join(@tables, ", ")} RESTART IDENTITY CASCADE")
    :ok
  end
end
