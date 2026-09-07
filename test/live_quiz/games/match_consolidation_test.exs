defmodule LiveQuiz.Games.MatchConsolidationTest do
  @moduledoc """
  Every way a question can end has to leave the same thing behind: a question
  closed, scored once, measured by its own clock.

  These are the regressions for R09-R12 of the review. Each one goes through
  the public flow a host and a player actually take — answer, advance, close,
  finish — rather than calling the scorer by hand, because calling it by hand
  is exactly what hid the missing orchestration.
  """

  use LiveQuiz.DataCase, async: false

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.GameSessionQuestion
  alias LiveQuiz.Games.Participant

  @duration 10

  describe "closing by the host" do
    setup :running_match

    test "counts a correct answer that arrived with no clock left", context do
      %{scope: scope, session: session, participant: participant} = context

      answer_at(context, 1, participant, :correct, @duration)

      assert {:ok, _closed} = Games.close_question(scope, session)

      reloaded = Repo.get!(Participant, participant.id)
      assert reloaded.score == 0
      assert reloaded.correct_answers == 1
      assert reloaded.incorrect_answers == 0
    end

    test "still counts a wrong answer as wrong", context do
      %{scope: scope, session: session, participant: participant} = context

      answer_at(context, 1, participant, :wrong, 2)

      assert {:ok, _closed} = Games.close_question(scope, session)

      reloaded = Repo.get!(Participant, participant.id)
      assert reloaded.score == 0
      assert reloaded.correct_answers == 0
      assert reloaded.incorrect_answers == 1
    end

    test "a missing answer is neither right nor wrong", context do
      %{scope: scope, session: session, participant: participant} = context

      assert {:ok, _closed} = Games.close_question(scope, session)

      reloaded = Repo.get!(Participant, participant.id)
      assert reloaded.correct_answers == 0
      assert reloaded.incorrect_answers == 0
    end

    test "ranks by correct answers when the scores tie", context do
      %{scope: scope, session: session, participant: slow} = context
      fast = participant_fixture(session, %{nickname: "Rápida"})

      # Both end on zero points: one answered right at the deadline, the other
      # answered wrong. The tie-break is the number of correct answers, so the
      # one who got it right has to come first.
      answer_at(context, 1, slow, :correct, @duration)
      answer_at(context, 1, fast, :wrong, 1)

      assert {:ok, _closed} = Games.close_question(scope, session)
      assert {:ok, ranking} = Games.current_ranking(reload(session), scope)

      assert [first, second] = ranking
      assert first.participant_id == slow.id
      assert first.correct_answers == 1
      assert second.participant_id == fast.id
    end
  end

  describe "advancing" do
    setup :running_match

    test "scores the question it leaves behind", context do
      %{scope: scope, session: session, participant: participant, questions: [first | _]} =
        context

      answer_at(context, 1, participant, :correct, 2)

      assert {:ok, advanced} = Games.advance_question(scope, session, 1)
      assert advanced.current_question_position == 2

      assert %DateTime{} = Repo.get!(GameSessionQuestion, first.id).scored_at

      reloaded = Repo.get!(Participant, participant.id)
      assert reloaded.score == 800
      assert reloaded.correct_answers == 1
      assert reloaded.total_response_time_ms == 2_000
    end

    test "counts a question exactly once when it was already closed", context do
      %{scope: scope, session: session, participant: participant} = context

      answer_at(context, 1, participant, :correct, 2)

      assert {:ok, closed} = Games.close_question(scope, session)
      assert {:ok, _advanced} = Games.advance_question(scope, closed, 1)

      reloaded = Repo.get!(Participant, participant.id)
      assert reloaded.score == 800
      assert reloaded.correct_answers == 1
    end

    test "two advances from the same position consolidate once", context do
      %{scope: scope, session: session, participant: participant} = context

      answer_at(context, 1, participant, :correct, 2)

      assert {:ok, _advanced} = Games.advance_question(scope, session, 1)
      assert Games.advance_question(scope, session, 1) == {:error, :stale}

      assert Repo.get!(Participant, participant.id).score == 800
    end

    test "re-scoring a question the room has left changes nothing", context do
      %{scope: scope, session: session, participant: participant} = context

      answer_at(context, 1, participant, :correct, 2)

      assert {:ok, advanced} = Games.advance_question(scope, session, 1)
      assert {:ok, _ranking} = Games.score_closed_question(advanced, 1)

      reloaded = Repo.get!(Participant, participant.id)
      assert reloaded.score == 800
      assert reloaded.total_response_time_ms == 2_000
    end

    test "measures each question by its own clock, not the next one's", context do
      %{participant: participant, questions: [first | _]} = context

      # Push the first question five seconds into the past, so the second one
      # starts at a visibly different instant. Without that the two clocks are
      # milliseconds apart and reading the wrong one looks almost right.
      %{scope: scope, session: session} = rewind_question(context, 1, 5)

      answer_at(context, 1, participant, :correct, 2)

      assert {:ok, advanced} = Games.advance_question(scope, session, 1)

      # The window R11 describes: a question closed but not yet consolidated
      # while the room moves on. Consolidating it now used to read the *second*
      # question's start and pay a full thousand points for an instant answer
      # that actually took two seconds. `scored_at` is cleared and the metrics
      # are put back to zero to stand where that call would have found them.
      Repo.update_all(
        from(q in GameSessionQuestion, where: q.id == ^first.id),
        set: [scored_at: nil]
      )

      Repo.update_all(
        from(p in Participant, where: p.id == ^participant.id),
        set: [score: 0, correct_answers: 0, incorrect_answers: 0, total_response_time_ms: 0]
      )

      assert {:ok, _ranking} = Games.score_closed_question(advanced, 1)

      reloaded = Repo.get!(Participant, participant.id)
      assert reloaded.score == 800
      assert reloaded.total_response_time_ms == 2_000
    end
  end

  describe "finishing" do
    setup :running_match

    test "consolidates the question that was still open", context do
      %{scope: scope, session: session, participant: participant} = context

      answer_at(context, 1, participant, :correct, 2)

      assert {:ok, _finished} = Games.finish_game_session(scope, session)

      reloaded = Repo.get!(Participant, participant.id)
      assert reloaded.score == 800
      assert reloaded.correct_answers == 1
    end

    test "the frozen result agrees with the metrics it was built from", context do
      %{scope: scope, session: session, participant: participant} = context

      answer_at(context, 1, participant, :correct, 2)

      assert {:ok, _finished} = Games.finish_game_session(scope, session)
      assert {:ok, result} = Games.get_game_result(scope, session.id, participant.id)

      assert result.question_results["1"]["correct"]
      assert result.correct_answers == 1
      assert result.score == 800
    end

    test "finishing after the question was closed changes nothing", context do
      %{scope: scope, session: session, participant: participant} = context

      answer_at(context, 1, participant, :correct, 2)

      assert {:ok, closed} = Games.close_question(scope, session)
      assert {:ok, _finished} = Games.finish_game_session(scope, closed)

      reloaded = Repo.get!(Participant, participant.id)
      assert reloaded.score == 800
      assert reloaded.correct_answers == 1
    end

    test "finishing twice does not count anything twice", context do
      %{scope: scope, session: session, participant: participant} = context

      answer_at(context, 1, participant, :correct, 2)

      assert {:ok, finished} = Games.finish_game_session(scope, session)
      assert {:ok, _again} = Games.finish_game_session(scope, finished)

      assert Repo.get!(Participant, participant.id).score == 800
    end

    test "finishing with nobody having answered leaves an empty tally", context do
      %{scope: scope, session: session, participant: participant} = context

      assert {:ok, _finished} = Games.finish_game_session(scope, session)

      reloaded = Repo.get!(Participant, participant.id)
      assert reloaded.score == 0
      assert reloaded.correct_answers == 0
      assert reloaded.incorrect_answers == 0
    end
  end

  describe "a question with no recoverable clock" do
    test "is refused instead of being scored against the wrong instant" do
      %{scope: scope, session: session, questions: [first | _]} = running_match(%{})

      assert {:ok, advanced} = Games.advance_question(scope, session, 1)

      # Only rows written before the snapshot carried its own clock can look
      # like this. Inventing a start for them would write a tally nothing later
      # could tell from a real one.
      Repo.update_all(
        from(q in GameSessionQuestion, where: q.id == ^first.id),
        set: [started_at: nil]
      )

      assert Games.score_closed_question(advanced, 1) == {:error, :missing_question_clock}
    end
  end

  defp running_match(_context) do
    host = user_fixture()
    scope = Scope.for_user(host)

    session =
      game_session_fixture(%{
        host: host,
        status: :in_progress,
        question_duration_seconds: @duration
      })

    questions = snapshot_fixture(session, count: 2)
    participant = participant_fixture(session)

    {:ok, opened} = Games.advance_question(scope, session, nil)
    Games.QuestionTimer.stop(opened.id)

    %{
      scope: scope,
      session: opened,
      questions: questions,
      participant: participant
    }
  end

  # Writes the answer the given number of seconds into the question's own clock,
  # so a test says "two seconds in" instead of doing the arithmetic itself.
  defp answer_at(%{questions: questions}, position, participant, correctness, seconds) do
    question = Enum.find(questions, &(&1.position == position))
    clock = Repo.get!(GameSessionQuestion, question.id)

    option =
      case correctness do
        :correct -> Enum.find(question.answer_options, & &1.is_correct)
        :wrong -> Enum.find(question.answer_options, &(not &1.is_correct))
      end

    answer_fixture(participant, option, %{
      answered_at: DateTime.add(clock.started_at, seconds, :second)
    })
  end

  # Moves the clock of the question the room is sitting on back in time, on the
  # room and on the question alike, and answers with the room as it now stands.
  defp rewind_question(%{session: session, questions: questions} = context, position, seconds) do
    question = Enum.find(questions, &(&1.position == position))
    clock = Repo.get!(GameSessionQuestion, question.id)
    started_at = DateTime.add(clock.started_at, -seconds, :second)
    ends_at = DateTime.add(clock.ends_at, -seconds, :second)

    Repo.update_all(
      from(q in GameSessionQuestion, where: q.id == ^question.id),
      set: [started_at: started_at, ends_at: ends_at]
    )

    Repo.update_all(
      from(s in GameSession, where: s.id == ^session.id),
      set: [current_question_started_at: started_at, current_question_ends_at: ends_at]
    )

    %{context | session: reload(session)}
  end

  defp reload(%GameSession{id: id}), do: Repo.get!(GameSession, id)
end
