defmodule LiveQuiz.Games.LockProtocolConcurrencyTest do
  @moduledoc """
  The interleavings the lock protocol exists for, run on real transactions.

  Each of these needs two backends: what is under test is a command that
  validated the room, then had to wait for a lock while another command changed
  the answer. On the shared sandbox connection there is no waiting and no
  commit to see, so the loser never loses.
  """

  use LiveQuiz.ConcurrencyCase

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.Participant

  describe "entering a room that is ending" do
    test "nobody stays seated in a room that was cancelled" do
      host = user_fixture()
      scope = Scope.for_user(host)
      session = game_session_fixture(%{host: host, status: :waiting})

      results =
        compete([
          fn -> Games.join_game_session(nil, session.join_code, %{nickname: "Ana"}) end,
          fn -> Games.cancel_game_session(scope, session) end
        ])

      assert Enum.any?(results, &match?({:ok, %GameSession{status: :cancelled}}, &1))
      assert_nobody_left_active(session)
    end

    test "nobody stays seated in a room that was expired" do
      session = game_session_fixture(%{status: :waiting})
      overdue = overdue_host_absence(session)

      results =
        compete([
          fn -> Games.join_game_session(nil, session.join_code, %{nickname: "Ana"}) end,
          fn -> Games.expire_game_session(overdue) end
        ])

      assert Enum.any?(results, &match?({:ok, %GameSession{status: :expired}}, &1))
      assert_nobody_left_active(session)
    end

    test "nobody stays seated in a room that finished" do
      host = user_fixture()
      scope = Scope.for_user(host)
      session = game_session_fixture(%{host: host, status: :in_progress})
      snapshot_fixture(session, count: 1)

      results =
        compete([
          fn -> Games.join_game_session(nil, session.join_code, %{nickname: "Ana"}) end,
          fn -> Games.finish_game_session(scope, session) end
        ])

      # A room in progress does not take newcomers, so the join is refused
      # either way; what matters is that finishing left nobody active behind it.
      assert Enum.any?(results, &match?({:ok, %GameSession{status: :finished}}, &1))
      assert_nobody_left_active(session)
    end
  end

  describe "coming back to a room that is ending" do
    test "a rejoin never restores a participation into a closed room" do
      host = user_fixture()
      scope = Scope.for_user(host)
      session = game_session_fixture(%{host: host, status: :waiting})
      {participant, token} = credentialed_participant_fixture(session)
      {:ok, _left} = Games.leave_game_session(participant)

      results =
        compete([
          fn -> Games.rejoin_game_session(token) end,
          fn -> Games.cancel_game_session(scope, session) end
        ])

      assert Enum.any?(results, &match?({:ok, %GameSession{status: :cancelled}}, &1))
      assert_nobody_left_active(session)
    end
  end

  describe "expiring a room" do
    test "two sweeps competing close it exactly once" do
      session = game_session_fixture(%{status: :waiting})
      overdue = overdue_host_absence(session)

      results =
        compete([
          fn -> Games.expire_game_session(overdue) end,
          fn -> Games.expire_game_session(overdue) end
        ])

      assert Enum.count(results, &match?({:ok, %GameSession{status: :expired}}, &1)) == 1
      assert Enum.count(results, &match?({:error, :invalid_transition}, &1)) == 1
    end

    test "loses to a host who cancels at the same instant" do
      host = user_fixture()
      scope = Scope.for_user(host)
      session = game_session_fixture(%{host: host, status: :waiting})
      overdue = overdue_host_absence(session)

      results =
        compete([
          fn -> Games.expire_game_session(overdue) end,
          fn -> Games.cancel_game_session(scope, session) end
        ])

      # Exactly one status, whichever won: the room cannot end twice.
      assert Enum.count(results, &match?({:ok, %GameSession{}}, &1)) == 1
      assert Repo.get!(GameSession, session.id).status in [:expired, :cancelled]
    end
  end

  describe "leaving" do
    test "twice at once stamps one departure" do
      session = game_session_fixture(%{status: :waiting})
      participant = participant_fixture(session)

      [{:ok, first}, {:ok, second}] =
        compete([
          fn -> Games.leave_game_session(participant) end,
          fn -> Games.leave_game_session(participant) end
        ])

      assert first.left_at == second.left_at
      assert Repo.get!(Participant, participant.id).left_at == first.left_at
    end
  end

  defp assert_nobody_left_active(%GameSession{id: id}) do
    active =
      Participant
      |> where([p], p.game_session_id == ^id and is_nil(p.released_at))
      |> Repo.all()

    assert active == [],
           "a room that ended left #{length(active)} participation(s) still tied to it"
  end
end
