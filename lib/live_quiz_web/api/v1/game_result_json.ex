defmodule LiveQuizWeb.Api.V1.GameResultJSON do
  @moduledoc "Serializes rankings, immutable results and paginated histories."

  alias LiveQuiz.Games.GameResult

  def ranking(%{ranking: ranking}), do: %{data: Enum.map(ranking, &ranking_data/1)}

  def result(%{result: %GameResult{} = result}), do: %{data: result_data(result)}

  def results(%{session: session}),
    do: %{
      data: %{
        session: session_data(session),
        results: Enum.map(session.game_results, &result_data/1)
      }
    }

  def history(%{page: page}), do: page_data(page, &result_data/1)

  def quiz_history(%{page: page}), do: page_data(page, &session_history_data/1)

  defp page_data(page, mapper) do
    %{
      data: Enum.map(page.entries, mapper),
      meta: %{
        page: page.page,
        per_page: page.per_page,
        total_entries: page.total_entries,
        total_pages: page.total_pages
      }
    }
  end

  defp ranking_data(entry),
    do:
      Map.take(entry, [
        :participant_id,
        :nickname,
        :score,
        :correct_answers,
        :incorrect_answers,
        :total_response_time_ms,
        :position
      ])

  defp result_data(%GameResult{} = result) do
    %{
      id: result.id,
      game_session_id: result.game_session_id,
      participant_id: result.participant_id,
      user_id: result.user_id,
      quiz_id: result.quiz_id,
      quiz_title: result.quiz_title,
      nickname: result.nickname,
      score: result.score,
      correct_answers: result.correct_answers,
      incorrect_answers: result.incorrect_answers,
      unanswered_questions: result.unanswered_questions,
      answered_questions: result.answered_questions,
      played_questions: result.played_questions,
      total_questions: result.total_questions,
      total_response_time_ms: result.total_response_time_ms,
      average_response_time_ms: result.average_response_time_ms,
      final_position: result.final_position,
      question_results: result.question_results,
      inserted_at: result.inserted_at
    }
  end

  defp session_data(session),
    do: %{
      id: session.id,
      code: session.join_code,
      quiz_id: session.quiz_id,
      quiz_title: session.quiz_title,
      status: session.status,
      finished_at: session.finished_at
    }

  defp session_history_data(entry) do
    session_data(entry.session)
    |> Map.merge(%{
      participants_count: entry.participants_count,
      winner_nickname: entry.winner_nickname,
      winner_score: entry.winner_score
    })
  end
end
