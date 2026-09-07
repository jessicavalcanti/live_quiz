defmodule LiveQuiz.RateLimitTest do
  use ExUnit.Case, async: false

  alias LiveQuiz.RateLimit

  setup {LiveQuiz.RateLimitSetup, :enforce}

  describe "hit/3" do
    test "spends the budget of the bucket and then refuses" do
      {limit, _window} = RateLimit.budget(:login_by_origin)

      for _attempt <- 1..limit do
        assert RateLimit.hit(:login_by_origin, "key") == :ok
      end

      assert {:error, retry_after} = RateLimit.hit(:login_by_origin, "key")
      assert retry_after > 0
    end

    test "counts each key on its own" do
      {limit, _window} = RateLimit.budget(:login_by_account)

      for _attempt <- 1..limit, do: RateLimit.hit(:login_by_account, "spent@example.com")

      assert {:error, _retry_after} = RateLimit.hit(:login_by_account, "spent@example.com")
      assert RateLimit.hit(:login_by_account, "other@example.com") == :ok
    end

    test "counts each bucket on its own, for the same key" do
      {limit, _window} = RateLimit.budget(:login_by_origin)

      for _attempt <- 1..limit, do: RateLimit.hit(:login_by_origin, "key")

      assert {:error, _retry_after} = RateLimit.hit(:login_by_origin, "key")
      assert RateLimit.hit(:join_by_origin, "key") == :ok
    end

    test "starts over when the window turns" do
      {limit, window} = RateLimit.budget(:login_by_origin)
      now = System.system_time(:millisecond)

      for _attempt <- 1..limit, do: RateLimit.hit(:login_by_origin, "key", now)
      assert {:error, _retry_after} = RateLimit.hit(:login_by_origin, "key", now)

      assert RateLimit.hit(:login_by_origin, "key", now + window) == :ok
    end

    test "answers with the seconds left of the window, never zero" do
      {limit, window} = RateLimit.budget(:login_by_origin)
      # The very last millisecond of a window: the honest answer is under a
      # second, and `Retry-After: 0` invites the retry that was just refused.
      now = div(System.system_time(:millisecond), window) * window + window - 1

      for _attempt <- 1..limit, do: RateLimit.hit(:login_by_origin, "key", now)

      assert RateLimit.hit(:login_by_origin, "key", now) == {:error, 1}

      start_of_window = div(now, window) * window

      for _attempt <- 1..limit, do: RateLimit.hit(:login_by_origin, "other", start_of_window)

      assert RateLimit.hit(:login_by_origin, "other", start_of_window) ==
               {:error, div(window, 1000)}
    end

    test "does nothing at all while it is disabled" do
      Application.put_env(:live_quiz, RateLimit, enabled: false)
      {limit, _window} = RateLimit.budget(:login_by_origin)

      for _attempt <- 1..(limit * 3) do
        assert RateLimit.hit(:login_by_origin, "key") == :ok
      end

      assert RateLimit.size() == 0
    end
  end

  describe "peek/3" do
    test "reads the state of a budget without spending it" do
      {limit, _window} = RateLimit.budget(:login_by_origin)

      for _attempt <- 1..(limit - 1), do: RateLimit.hit(:login_by_origin, "key")

      assert RateLimit.peek(:login_by_origin, "key") == :ok
      assert RateLimit.peek(:login_by_origin, "key") == :ok

      # Still one attempt left, which peeking twice did not take.
      assert RateLimit.hit(:login_by_origin, "key") == :ok
      assert {:error, _retry_after} = RateLimit.hit(:login_by_origin, "key")
    end

    test "says nothing is spent for a key nobody has used" do
      assert RateLimit.peek(:login_by_origin, "unknown") == :ok
    end
  end

  describe "sweep/1" do
    test "drops the rows of windows that are over and keeps the current one" do
      {_limit, window} = RateLimit.budget(:login_by_origin)
      now = System.system_time(:millisecond)

      RateLimit.hit(:login_by_origin, "old", now - 3 * window)
      RateLimit.hit(:login_by_origin, "current", now)

      assert RateLimit.size() == 2

      RateLimit.sweep(now)

      assert RateLimit.size() == 1
      # And the budget that survived is the one still being spent.
      assert RateLimit.peek(:login_by_origin, "current", now) == :ok
    end

    test "leaves a bucket whose window has not turned yet alone" do
      now = System.system_time(:millisecond)

      # An hour long window, hit now: no sweep in the next minutes touches it.
      RateLimit.hit(:password_reset_by_origin, "key", now)
      RateLimit.sweep(now + :timer.minutes(5))

      assert RateLimit.size() == 1
    end
  end

  describe "the sweep on the timer" do
    test "the process itself clears what is over" do
      {_limit, window} = RateLimit.budget(:login_by_origin)

      RateLimit.hit(:login_by_origin, "old", System.system_time(:millisecond) - 5 * window)
      assert RateLimit.size() == 1

      send(RateLimit, :sweep)
      # A call is answered after the message that arrived before it, so this is
      # the sweep having finished rather than a guess about when it did.
      :sys.get_state(RateLimit)

      assert RateLimit.size() == 0
    end
  end

  describe "the cardinality it holds" do
    test "stops counting rather than growing without a bound" do
      # Filling the table is the only honest way to reach the cap. What is
      # asserted is the decision it makes there: a limiter that turned memory
      # pressure into an outage would have become the attack.
      for key <- 1..100_000, do: RateLimit.hit(:login_by_origin, key)

      assert RateLimit.size() >= 100_000

      handler = attach_overflow_handler()
      {limit, _window} = RateLimit.budget(:login_by_origin)

      for _attempt <- 1..(limit * 2) do
        assert RateLimit.hit(:login_by_origin, "beyond the cap") == :ok
      end

      assert_receive {:overflow, %{bucket: :login_by_origin}}
      :telemetry.detach(handler)
    end
  end

  describe "the budgets themselves" do
    test "every bucket has a positive limit and a positive window" do
      for bucket <- RateLimit.buckets() do
        assert {limit, window} = RateLimit.budget(bucket)
        assert limit > 0, "#{bucket} has a limit of #{limit}"
        assert window > 0, "#{bucket} has a window of #{window}"
      end
    end

    test "an unknown bucket is a mistake in the code, not a request to allow" do
      assert_raise FunctionClauseError, fn -> RateLimit.hit(:nonexistent, "key") end
    end
  end

  defp attach_overflow_handler do
    handler = "overflow-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      handler,
      [:live_quiz, :rate_limit, :overflow],
      fn _event, _measurements, metadata, _config -> send(test, {:overflow, metadata}) end,
      nil
    )

    handler
  end
end
