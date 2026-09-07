defmodule LiveQuiz.Games.LockProtocolTest do
  @moduledoc """
  Commands that decide on the row rather than on the struct that reached them.

  Regressions for R16, R17, R23 and R24 of the review. The read that authorizes
  a command happens before its lock is granted; by the time it runs, the winner
  of the race has already changed the answer. Each of these used to act on the
  earlier reading.

  The races themselves are in `LiveQuiz.Games.LockProtocolConcurrencyTest`,
  where the competitors have their own connections.
  """

  use LiveQuiz.DataCase, async: false

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import LiveQuiz.QuizzesFixtures

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.Participant

  describe "expiring a room" do
    test "refuses a room whose host came back after it was listed" do
      session = game_session_fixture(%{status: :waiting})
      overdue = overdue_host_absence(session)

      # What the sweeper holds is the room as it was when it was listed. The
      # host returning cleared the deadline it was selected on.
      assert {:ok, returned} = Games.mark_host_connected(overdue)
      assert is_nil(returned.expires_at)

      assert Games.expire_game_session(overdue) == {:error, :not_expired}
      assert Repo.get!(GameSession, session.id).status == :waiting
    end

    test "refuses a room whose deadline was renewed by a new absence" do
      session = game_session_fixture(%{status: :waiting})
      overdue = overdue_host_absence(session)

      {:ok, _returned} = Games.mark_host_connected(overdue)
      {:ok, away_again} = Games.mark_host_disconnected(Repo.get!(GameSession, session.id))

      assert Games.expire_game_session(overdue) == {:error, :not_expired}
      assert away_again.expires_at
      assert Repo.get!(GameSession, session.id).status == :waiting
    end

    test "refuses a room whose deadline has not run out yet" do
      session = game_session_fixture(%{status: :waiting})
      {:ok, away} = Games.mark_host_disconnected(session)

      assert Games.expire_game_session(away) == {:error, :not_expired}
      assert Repo.get!(GameSession, session.id).status == :waiting
    end

    test "refuses a room that carries no deadline at all" do
      session = game_session_fixture(%{status: :waiting})

      assert Games.expire_game_session(session) == {:error, :not_expired}
    end

    test "still expires a room the deadline really ran out on" do
      session = game_session_fixture(%{status: :waiting})

      assert {:ok, expired} = session |> overdue_host_absence() |> Games.expire_game_session()
      assert expired.status == :expired
    end

    test "is idempotent: a second sweep finds nothing to close" do
      session = game_session_fixture(%{status: :waiting})
      overdue = overdue_host_absence(session)

      assert {:ok, _expired} = Games.expire_game_session(overdue)
      assert Games.expire_game_session(overdue) == {:error, :invalid_transition}
    end
  end

  describe "leaving a room" do
    setup :waiting_room

    test "twice with the same struct announces one departure", %{session: session} do
      participant = participant_fixture(session)
      :ok = Games.subscribe(session.id)

      assert {:ok, left} = Games.leave_game_session(participant)
      assert_receive {:participant_left, %Participant{}}

      # The very struct that was already used once. Deciding on it would stamp
      # the instant again and replay the departure.
      assert {:ok, again} = Games.leave_game_session(participant)

      assert again.left_at == left.left_at
      refute_receive {:participant_left, _repeated}, 50
    end

    test "with a struct read before a rejoin does not undo the return", %{session: session} do
      {participant, token} = credentialed_participant_fixture(session)
      {:ok, _left} = Games.leave_game_session(participant)
      stale = Repo.get!(Participant, participant.id)

      assert {:ok, back} = Games.rejoin_game_session(token)
      assert is_nil(back.left_at)

      # `stale` says the person is gone; the row says they came back. Only the
      # row decides, so this really is a departure and not a no-op.
      assert {:ok, gone} = Games.leave_game_session(stale)
      assert gone.left_at
      assert Repo.get!(Participant, participant.id).left_at
    end

    test "does not rewrite why somebody the room released is gone", %{session: session} do
      released_at = DateTime.add(DateTime.utc_now(:second), -600, :second)
      participant = participant_fixture(session, %{released_at: released_at})

      assert {:ok, unchanged} = Games.leave_game_session(participant)

      assert is_nil(unchanged.left_at)
      assert unchanged.released_at == released_at
    end
  end

  describe "opening a room" do
    test "validates the quiz as it stands under the lock, not as it was read" do
      user = user_fixture()
      scope = Scope.for_user(user)
      quiz = quiz_fixture(scope, %{title: "Antes"})
      question_fixture(scope, quiz)

      {:ok, _renamed} = LiveQuiz.Quizzes.update_quiz(scope, quiz, %{title: "Depois"})

      assert {:ok, session} = Games.create_game_session(scope, quiz.id)
      assert session.quiz_title == "Depois"
    end

    test "refuses a quiz whose last question is gone" do
      user = user_fixture()
      scope = Scope.for_user(user)
      quiz = quiz_fixture(scope)
      question = question_fixture(scope, quiz)

      {:ok, _deleted} = LiveQuiz.Quizzes.delete_question(scope, question)

      assert Games.create_game_session(scope, quiz.id) == {:error, :quiz_not_playable}
    end
  end

  defp waiting_room(_context) do
    %{session: game_session_fixture(%{status: :waiting})}
  end
end
