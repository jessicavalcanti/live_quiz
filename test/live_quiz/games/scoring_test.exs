defmodule LiveQuiz.Games.ScoringTest do
  use LiveQuiz.DataCase, async: false

  import LiveQuiz.GamesFixtures

  alias LiveQuiz.Games
  alias LiveQuiz.Games.Answer
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.GameSessionQuestion
  alias LiveQuiz.Games.Participant

  describe "calculate_answer_score/3" do
    setup :scoring_context

    test "returns 1000, 500 and 0 for 0%, 50% and 100% remaining", context do
      %{answer: answer, question: question, session: session} = context

      assert Games.calculate_answer_score(answer, question, session) == 1_000

      assert Games.calculate_answer_score(
               %{answer | answered_at: plus(session, 5)},
               question,
               session
             ) == 500

      assert Games.calculate_answer_score(
               %{answer | answered_at: plus(session, 10)},
               question,
               session
             ) == 0
    end

    test "returns zero for an incorrect or missing answer", %{
      question: question,
      session: session
    } do
      wrong = Enum.find(question.answer_options, &(!&1.is_correct))

      answer = %Answer{
        game_session_answer_option_id: wrong.id,
        answered_at: session.current_question_started_at
      }

      assert Games.calculate_answer_score(answer, question, session) == 0
      assert Games.calculate_answer_score(nil, question, session) == 0
    end

    test "accepts an answer exactly at the deadline", %{
      answer: answer,
      question: question,
      session: session
    } do
      at_deadline = %{answer | answered_at: session.current_question_ends_at}

      assert Games.calculate_answer_score(at_deadline, question, session) == 0
    end
  end

  describe "score_closed_question/2" do
    test "consolidates correct, incorrect and unanswered metrics and publishes after commit" do
      %{session: session, question: question} = closed_context()
      first = participant_fixture(session)
      second = participant_fixture(session)
      third = participant_fixture(session)
      correct = Enum.find(question.answer_options, & &1.is_correct)
      wrong = Enum.find(question.answer_options, &(!&1.is_correct))
      answer_fixture(first, correct, %{answered_at: session.current_question_started_at})
      answer_fixture(second, wrong, %{answered_at: session.current_question_started_at})
      :ok = Games.subscribe(session.id)

      assert {:ok, ranking} = Games.score_closed_question(session, 1)
      assert length(ranking) == 3
      assert reload_participant(first).correct_answers == 1
      assert reload_participant(first).score == 1_000
      assert reload_participant(second).incorrect_answers == 1
      assert reload_participant(third).score == 0
      assert_receive {:question_scored, %GameSession{}, ^ranking}
    end

    test "uses the last persisted answer after a choice change" do
      %{session: session, question: question} = closed_context()
      participant = participant_fixture(session)
      correct = Enum.find(question.answer_options, & &1.is_correct)
      wrong = Enum.find(question.answer_options, &(!&1.is_correct))

      answer =
        answer_fixture(participant, wrong, %{answered_at: session.current_question_started_at})

      Repo.update_all(from(a in Answer, where: a.id == ^answer.id),
        set: [
          game_session_answer_option_id: correct.id,
          answered_at: session.current_question_started_at
        ]
      )

      assert {:ok, _} = Games.score_closed_question(session, 1)
      assert reload_participant(participant).correct_answers == 1
      assert reload_participant(participant).incorrect_answers == 0
    end

    test "is idempotent and safe under concurrent calls" do
      %{session: session, question: question} = closed_context()
      participant = participant_fixture(session)
      correct = Enum.find(question.answer_options, & &1.is_correct)
      answer_fixture(participant, correct, %{answered_at: session.current_question_started_at})

      results =
        1..2
        |> Task.async_stream(fn _ -> Games.score_closed_question(session, 1) end, ordered: true)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert reload_participant(participant).correct_answers == 1
      assert reload_question(question).scored_at
    end

    test "scores 25 participants and keeps disconnected metrics" do
      %{session: session, question: question} = closed_context()
      participants = for _ <- 1..25, do: participant_fixture(session)
      correct = Enum.find(question.answer_options, & &1.is_correct)

      for participant <- participants do
        answer_fixture(participant, correct, %{answered_at: session.current_question_started_at})
      end

      disconnected = hd(participants)

      Repo.update_all(from(p in Participant, where: p.id == ^disconnected.id),
        set: [connection_id: nil]
      )

      assert {:ok, ranking} = Games.score_closed_question(session, 1)
      assert length(ranking) == 25
      assert reload_participant(disconnected).correct_answers == 1
    end

    test "stamps the response time on every answered question" do
      %{session: session, question: question} = closed_context()
      participant = participant_fixture(session)
      correct = Enum.find(question.answer_options, & &1.is_correct)

      answer =
        answer_fixture(participant, correct, %{
          answered_at: DateTime.add(session.current_question_started_at, 2_500, :millisecond)
        })

      assert {:ok, _ranking} = Games.score_closed_question(session, 1)
      assert Repo.get!(Answer, answer.id).response_time_ms == 2_500
      assert reload_participant(participant).total_response_time_ms == 2_500
    end

    test "rejects an open question and an unknown position" do
      %{session: session, question: question} = closed_context()

      Repo.update_all(from(s in GameSession, where: s.id == ^session.id),
        set: [current_question_closed_at: nil]
      )

      assert Games.score_closed_question(session, 1) == {:error, :question_open}

      Repo.update_all(from(s in GameSession, where: s.id == ^session.id),
        set: [current_question_closed_at: session.current_question_ends_at]
      )

      Repo.delete!(question)
      assert Games.score_closed_question(session, question.position) == {:error, :not_found}
    end
  end

  defp scoring_context(_context) do
    session = game_session_fixture(%{status: :in_progress, question_duration_seconds: 10})
    question = hd(snapshot_fixture(session, count: 1))
    started_at = ~U[2026-09-06 12:00:00.000000Z]
    ends_at = DateTime.add(started_at, 10, :second)

    Repo.update_all(from(s in GameSession, where: s.id == ^session.id),
      set: [
        current_question_position: 1,
        current_question_started_at: started_at,
        current_question_ends_at: ends_at
      ]
    )

    session = %{
      session
      | current_question_position: 1,
        current_question_started_at: started_at,
        current_question_ends_at: ends_at
    }

    answer = %Answer{
      game_session_answer_option_id: hd(question.answer_options).id,
      answered_at: started_at
    }

    %{session: session, question: question, answer: answer}
  end

  defp closed_context do
    %{session: session, question: question} = scoring_context(%{})
    closed_at = session.current_question_ends_at

    Repo.update_all(from(s in GameSession, where: s.id == ^session.id),
      set: [current_question_closed_at: closed_at]
    )

    session = %{session | current_question_closed_at: closed_at}
    %{session: session, question: question}
  end

  defp plus(session, seconds),
    do: DateTime.add(session.current_question_started_at, seconds, :second)

  defp reload_participant(participant), do: Repo.get!(Participant, participant.id)
  defp reload_question(question), do: Repo.get!(GameSessionQuestion, question.id)
end
