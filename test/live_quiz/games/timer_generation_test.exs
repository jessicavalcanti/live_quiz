defmodule LiveQuiz.Games.TimerGenerationTest do
  @moduledoc """
  A timer command that names the room and not the question.

  Regression for R18 of the review. The effects of closing and advancing run
  after their transaction commits, from different processes, so by the time one
  of them reaches the timer the match may already be a question further on. A
  command that named only the room could not tell the difference.
  """

  use LiveQuiz.DataCase, async: false

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.QuestionTimer

  describe "stopping a timer" do
    setup :open_question

    test "a stop for the question that was left behind spares the new one", %{
      scope: scope,
      session: session
    } do
      assert {:ok, second} = Games.advance_question(scope, session, 1)
      assert QuestionTimer.timing(second.id) == 2

      # The stop that closing question 1 scheduled, arriving after the host
      # advanced. Naming only the room, it used to take down the timer of
      # question 2 and leave it with no deadline at all.
      :ok = QuestionTimer.stop(session.id, 1)

      assert QuestionTimer.whereis(session.id)
      assert QuestionTimer.timing(session.id) == 2
    end

    test "a stop for the question being timed does stop it", %{session: session} do
      assert QuestionTimer.timing(session.id) == 1

      :ok = QuestionTimer.stop(session.id, 1)

      refute QuestionTimer.whereis(session.id)
    end

    test "a stop that names no question stops whatever is there", %{session: session} do
      :ok = QuestionTimer.stop(session.id)

      refute QuestionTimer.whereis(session.id)
    end

    test "a stop given a nil position stops whatever is there", %{session: session} do
      # The transitions that end a room have no question left to name. Passing
      # `nil` is that case spelled out, and it means the same as naming nothing.
      :ok = QuestionTimer.stop(session.id, nil)

      refute QuestionTimer.whereis(session.id)
    end

    test "closing a question leaves the next one armed", %{scope: scope, session: session} do
      assert {:ok, closed} = Games.close_question(scope, session)
      assert {:ok, second} = Games.advance_question(scope, closed, 1)

      assert QuestionTimer.whereis(second.id)
      assert QuestionTimer.timing(second.id) == 2
    end
  end

  describe "re-arming a timer" do
    setup :open_question

    test "a re-arm for a question already left behind is ignored", %{
      scope: scope,
      session: session
    } do
      assert {:ok, second} = Games.advance_question(scope, session, 1)
      assert QuestionTimer.timing(second.id) == 2

      # The struct of question 1, arriving late. Honouring it would point the
      # timer at a question the match has left, and the next check would find
      # the mismatch — leaving question 2 unscheduled.
      assert {:ok, _pid} = QuestionTimer.ensure_started(session)

      assert QuestionTimer.timing(second.id) == 2
    end

    test "a re-arm for the question that is current is honoured", %{session: session} do
      assert {:ok, _pid} = QuestionTimer.ensure_started(session)

      assert QuestionTimer.timing(session.id) == 1
    end
  end

  describe "a timer that fell behind" do
    setup :open_question

    test "follows the match instead of giving up", %{scope: scope, session: session} do
      pid = QuestionTimer.whereis(session.id)

      # The match moves on without the timer being told: this is the state a
      # lost effect leaves behind.
      Repo.update_all(from(s in GameSession, where: s.id == ^session.id),
        set: [current_question_position: 2, current_question_closed_at: nil]
      )

      assert QuestionTimer.fire_now(session.id) == :ok

      assert Process.alive?(pid)
      assert QuestionTimer.timing(session.id) == 2
    end

    test "closes only the question it was armed for", %{scope: scope, session: session} do
      overdue(session)
      assert {:ok, advanced} = Games.advance_question(scope, session, 1)
      :ok = Games.subscribe(advanced.id)

      # A closing that names question 1 while the match sits on question 2. The
      # position travels with it, so the lock serializes it and it writes
      # nothing.
      assert Games.close_question_by_timeout(session.id, 1) == {:error, :stale}

      current = Repo.get!(GameSession, session.id)
      assert current.current_question_position == 2
      assert is_nil(current.current_question_closed_at)
      refute_receive {:question_closed, _nothing}, 100
    end

    test "a closing that names the current question still works", %{session: session} do
      overdue(session)

      assert {:ok, closed} = Games.close_question_by_timeout(session.id, 1)
      assert closed.current_question_closed_at
    end

    test "a closing that names no question keeps the old contract", %{session: session} do
      overdue(session)

      assert {:ok, closed} = Games.close_question_by_timeout(session.id)
      assert closed.current_question_closed_at
    end
  end

  defp open_question(_context) do
    host = user_fixture()
    scope = Scope.for_user(host)
    session = game_session_fixture(%{host: host, status: :in_progress})
    snapshot_fixture(session, count: 3)

    {:ok, opened} = Games.advance_question(scope, session, nil)
    on_exit(fn -> QuestionTimer.stop(opened.id) end)

    %{scope: scope, session: opened}
  end

  defp overdue(%GameSession{id: id}) do
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    Repo.update_all(from(s in GameSession, where: s.id == ^id),
      set: [current_question_started_at: past, current_question_ends_at: past]
    )
  end
end
