defmodule LiveQuiz.Games.AnswerPopulationTest do
  @moduledoc """
  Who a number is about, and which instant it was taken at.

  Regressions for R13-R15 of the review. Each of the three was a number
  counted over one population and compared against another: absences over
  questions nobody was shown, answers over people the denominator had dropped,
  and a deadline tested at one instant while the answer was written at a later
  one.
  """

  use LiveQuiz.DataCase, async: false

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games
  alias LiveQuiz.Games.Answer
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.GameSessionQuestion

  describe "questions the match never applied" do
    setup :two_question_match

    test "are not absences of the person who was never shown them", context do
      %{scope: scope, session: session, participant: participant} = context

      answer_first(context, participant)

      assert {:ok, _finished} = Games.finish_game_session(scope, session)
      assert {:ok, result} = Games.get_game_result(scope, session.id, participant.id)

      assert result.answered_questions == 1
      assert result.unanswered_questions == 0
      assert result.played_questions == 1
      assert result.total_questions == 2
    end

    test "are absences only among the ones that were applied", context do
      %{scope: scope, session: session, participant: participant} = context
      silent = participant_fixture(session, %{nickname: "Calada"})

      answer_first(context, participant)

      assert {:ok, _finished} = Games.finish_game_session(scope, session)
      assert {:ok, result} = Games.get_game_result(scope, session.id, silent.id)

      assert result.answered_questions == 0
      assert result.unanswered_questions == 1
      assert result.played_questions == 1
      assert result.total_questions == 2
    end

    test "leave no detail behind in the frozen result", context do
      %{scope: scope, session: session, participant: participant} = context

      answer_first(context, participant)

      assert {:ok, _finished} = Games.finish_game_session(scope, session)
      assert {:ok, result} = Games.get_game_result(scope, session.id, participant.id)

      assert Map.keys(result.question_results) == ["1"]
    end

    test "the answered and the missing always add up to what was played", context do
      %{scope: scope, session: session, participant: participant} = context

      answer_first(context, participant)
      assert {:ok, advanced} = Games.advance_question(scope, session, 1)
      Games.QuestionTimer.stop(advanced.id)

      assert {:ok, _finished} = Games.finish_game_session(scope, advanced)
      assert {:ok, result} = Games.get_game_result(scope, session.id, participant.id)

      assert result.answered_questions + result.unanswered_questions ==
               result.played_questions

      assert result.played_questions == 2
      assert result.total_questions == 2
    end

    test "a match that ends before the first question played nothing" do
      host = user_fixture()
      scope = Scope.for_user(host)
      session = game_session_fixture(%{host: host, status: :in_progress})
      snapshot_fixture(session, count: 2)
      only = participant_fixture(session, %{nickname: "Sozinha"})

      assert {:ok, _finished} = Games.finish_game_session(scope, session)
      assert {:ok, result} = Games.get_game_result(scope, session.id, only.id)

      assert result.played_questions == 0
      assert result.total_questions == 2
      assert result.unanswered_questions == 0
      assert result.answered_questions == 0
      assert result.question_results == %{}
    end

    test "the summary counts what was applied, not the position on screen", context do
      %{scope: scope, session: session} = context

      assert {:ok, summary} = Games.game_summary(session, scope)
      assert summary.questions_played == 1
      assert summary.question_count == 2
    end
  end

  describe "the deadline that accepts an answer" do
    setup :two_question_match

    test "is the same instant the answer is written with", context do
      %{session: session} = context

      # A deadline a hair away, taken many times over. The check used to read
      # one clock and the write another, several queries later, so an answer
      # could pass the check and land persisted past the deadline it was
      # measured against (R14).
      for _attempt <- 1..40 do
        participant = participant_fixture(session)
        ends_at = DateTime.add(DateTime.utc_now(), 1, :millisecond)
        set_deadline(session, ends_at)

        case Games.answer_question(participant, first_option(context).id, []) do
          {:ok, %{answer: %Answer{answered_at: answered_at}}} ->
            assert DateTime.compare(answered_at, ends_at) != :gt,
                   "an answer accepted before #{ends_at} was written at #{answered_at}"

          {:error, :time_is_up} ->
            assert Repo.aggregate(
                     where(Answer, [a], a.participant_id == ^participant.id),
                     :count
                   ) == 0
        end
      end
    end
  end

  describe "the population a question's numbers are about" do
    setup :two_question_match

    test "includes somebody who answered and then walked out", context do
      %{scope: scope, session: session, participant: participant} = context

      answer_first(context, participant)
      assert {:ok, _left} = Games.leave_game_session(participant)

      assert {:ok, closed} = Games.close_question(scope, session)
      assert {:ok, results} = Games.question_results(closed, 1, scope)

      assert results.answers_count == 1
      assert results.participants_count == 1
      assert results.no_answer_count == 0
    end

    test "never reports more answers than people", context do
      %{scope: scope, session: session, participant: participant} = context
      staying = participant_fixture(session, %{nickname: "Fica"})

      answer_first(context, participant)
      answer_first(context, staying)
      assert {:ok, _left} = Games.leave_game_session(participant)

      assert {:ok, closed} = Games.close_question(scope, session)
      assert {:ok, results} = Games.question_results(closed, 1, scope)

      assert results.answers_count == 2
      assert results.participants_count == 2
      assert results.no_answer_count == 0
      assert Enum.sum(Enum.map(results.options, & &1.count)) == results.answers_count
    end

    test "still counts as absent whoever merely dropped off", context do
      %{scope: scope, session: session, participant: participant} = context
      participant_fixture(session, %{nickname: "Caiu"})

      answer_first(context, participant)

      assert {:ok, closed} = Games.close_question(scope, session)
      assert {:ok, results} = Games.question_results(closed, 1, scope)

      assert results.answers_count == 1
      assert results.participants_count == 2
      assert results.no_answer_count == 1
    end
  end

  describe "closing because everybody connected answered" do
    setup :two_question_match

    test "does not let an answer from somebody who left stand in for somebody present",
         context do
      %{session: session, participant: gone} = context
      present = participant_fixture(session, %{nickname: "Presente"})
      missing = participant_fixture(session, %{nickname: "Faltando"})
      option = first_option(context)

      # Two answers and two connected participations, and the rule used to
      # compare those two totals. They are different people: `gone` answered and
      # dropped off, so `missing` had not answered yet when the question closed
      # on them (R15).
      assert {:ok, %{closed?: false}} =
               Games.answer_question(gone, option.id, [present.id, missing.id])

      assert {:ok, %{closed?: false}} =
               Games.answer_question(present, option.id, [present.id, missing.id])

      assert GameSession.question_open?(Repo.get!(GameSession, session.id))

      assert {:ok, %{closed?: true}} =
               Games.answer_question(missing, option.id, [present.id, missing.id])

      refute GameSession.question_open?(Repo.get!(GameSession, session.id))
    end

    test "closes as soon as every connected participation has answered", context do
      %{session: session, participant: connected} = context
      participant_fixture(session, %{nickname: "Desconectada"})

      assert {:ok, %{closed?: true}} =
               Games.answer_question(connected, first_option(context).id, [connected.id])
    end
  end

  defp two_question_match(_context) do
    host = user_fixture()
    scope = Scope.for_user(host)
    session = game_session_fixture(%{host: host, status: :in_progress})
    questions = snapshot_fixture(session, count: 2)
    participant = participant_fixture(session)

    {:ok, opened} = Games.advance_question(scope, session, nil)
    Games.QuestionTimer.stop(opened.id)

    %{scope: scope, session: opened, questions: questions, participant: participant}
  end

  defp first_option(%{questions: questions}) do
    questions |> Enum.find(&(&1.position == 1)) |> Map.fetch!(:answer_options) |> hd()
  end

  defp answer_first(context, participant) do
    clock = Repo.get!(GameSessionQuestion, first_option(context).game_session_question_id)

    answer_fixture(participant, first_option(context), %{
      answered_at: DateTime.add(clock.started_at, 1, :second)
    })
  end

  defp set_deadline(%GameSession{id: id}, ends_at) do
    Repo.update_all(from(s in GameSession, where: s.id == ^id),
      set: [current_question_ends_at: ends_at]
    )
  end
end
