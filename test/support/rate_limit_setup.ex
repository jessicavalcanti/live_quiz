defmodule LiveQuiz.RateLimitSetup do
  @moduledoc """
  Turns the budgets on for one test case, and off again afterwards.

  `LiveQuiz.RateLimit` is disabled in `:test` because its table is shared by
  the whole node: a budget spent by one async case would be missing from
  another, and the failure would land on whichever case ran second. A case that
  wants the budgets enforced therefore runs with `async: false`, which ExUnit
  runs after every async case and one at a time — the only arrangement in which
  a global counter means what the test says it means.

      use LiveQuizWeb.ConnCase, async: false

      setup {LiveQuiz.RateLimitSetup, :enforce}

  """

  alias LiveQuiz.RateLimit

  @doc "Enables the budgets and hands back a clean table."
  @spec enforce(map()) :: :ok
  def enforce(_context) do
    Application.put_env(:live_quiz, RateLimit, enabled: true)
    RateLimit.reset()

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:live_quiz, RateLimit, enabled: false)
      RateLimit.reset()
    end)

    :ok
  end
end
