defmodule LiveQuiz.GamesConcurrencyTest do
  @moduledoc """
  The rules that only hold because two transactions serialize, proved with two
  transactions.

  Everything here also exists in `LiveQuiz.GamesTest`, where the competitors
  share the sandbox's single connection and therefore take turns rather than
  race. Those tests say the outcome is right for one interleaving; these say
  the lock that produces it is really taken, on real backends, with real
  commits in between.
  """

  use LiveQuiz.ConcurrencyCase

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures

  alias LiveQuiz.Accounts
  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession

  describe "the case itself" do
    test "competitors run on distinct PostgreSQL backends" do
      assert_distinct_backends(4)
    end

    test "a competitor sees what another one committed" do
      host = user_fixture()
      scope = Scope.for_user(host)
      session = game_session_fixture(host: host)
      gate = Gate.start!()

      reader =
        Task.async(fn ->
          Gate.pause(gate, :after_the_write)
          Repo.get!(GameSession, session.id).status
        end)

      # Committed on its own connection. Under the shared sandbox connection
      # there would be no commit to see: everything would still be inside the
      # one transaction the test rolls back at the end.
      [{:ok, _cancelled}] = compete([fn -> Games.cancel_game_session(scope, session) end])

      Gate.await_paused(gate, :after_the_write)
      Gate.release(gate, :after_the_write)

      assert Task.await(reader) == :cancelled
    end

    test "tables are empty at the start of each test" do
      assert Repo.aggregate(GameSession, :count) == 0
    end
  end

  describe "seats" do
    test "the last seat goes to exactly one of the people racing for it" do
      session = game_session_fixture(status: :waiting)
      for _ <- 1..(Games.max_participants() - 1), do: participant_fixture(session)

      assert Games.available_slots(session) == 1

      results =
        compete(
          for index <- 1..5 do
            fn -> Games.join_game_session(nil, session.join_code, %{nickname: "P#{index}"}) end
          end
        )

      assert Enum.count(results, &match?({:ok, _participant, _token}, &1)) == 1
      assert Enum.count(results, &match?({:error, :session_full}, &1)) == 4
      assert Games.available_slots(reload(session)) == 0
    end

    test "a room never goes over its seats when everyone arrives at once" do
      session = game_session_fixture(status: :waiting)
      free = 5
      for _ <- 1..(Games.max_participants() - free), do: participant_fixture(session)

      # More competitors than free seats, few enough to each hold a connection:
      # what is under test is the seat cap under real contention, not how many
      # tasks the pool can serve.
      results =
        compete(
          for index <- 1..(free * 2) do
            fn -> Games.join_game_session(nil, session.join_code, %{nickname: "P#{index}"}) end
          end
        )

      assert Enum.count(results, &match?({:ok, _participant, _token}, &1)) == free
      assert Enum.count(results, &match?({:error, :session_full}, &1)) == free
      assert Games.available_slots(reload(session)) == 0
    end
  end

  describe "identity" do
    test "one account cannot enter two rooms by racing them" do
      user = user_fixture()
      scope = Scope.for_user(user)
      first = game_session_fixture(status: :waiting)
      second = game_session_fixture(status: :waiting)

      results =
        compete([
          fn -> Games.join_game_session(scope, first.join_code, %{nickname: "Ana"}) end,
          fn -> Games.join_game_session(scope, second.join_code, %{nickname: "Ana"}) end
        ])

      assert Enum.count(results, &match?({:ok, _participant, _token}, &1)) == 1
      assert Enum.count(results, &match?({:error, _reason}, &1)) == 1
    end
  end

  describe "password reset" do
    test "two submits of the same link on independent connections reset once" do
      user = user_fixture()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_reset_password_instructions(user, url)
        end)

      results =
        compete([
          fn -> Accounts.reset_user_password(token, %{password: "first valid password"}) end,
          fn -> Accounts.reset_user_password(token, %{password: "second valid password"}) end
        ])

      assert Enum.count(results, &match?({:ok, {_user, _tokens}}, &1)) == 1
      assert Enum.count(results, &match?({:error, :invalid_token}, &1)) == 1
      refute Accounts.get_user_by_reset_password_token(token)
    end
  end

  defp reload(%GameSession{id: id}), do: Repo.get!(GameSession, id)
end
