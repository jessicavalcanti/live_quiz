defmodule LiveQuizWeb.Api.V1.Schemas.GameResultResponse do
  @moduledoc "Schema for one immutable game result."

  alias LiveQuizWeb.Api.V1.Schemas.GameResult
  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "GameResultResponse",
      description: "Resultado imutável de um participante.",
      type: :object,
      properties: %{data: GameResult},
      required: [:data],
      example: %{
        "data" => %{
          "id" => 301,
          "game_session_id" => 12,
          "participant_id" => 88,
          "user_id" => nil,
          "quiz_id" => 7,
          "quiz_title" => "Geografia",
          "nickname" => "Ana",
          "score" => 900,
          "correct_answers" => 9,
          "incorrect_answers" => 1,
          "unanswered_questions" => 0,
          "answered_questions" => 10,
          "played_questions" => 10,
          "total_questions" => 10,
          "total_response_time_ms" => 12_400,
          "average_response_time_ms" => 1240,
          "final_position" => 1,
          "question_results" => %{
            "1" => %{
              "question" => "Qual é a capital do Brasil?",
              "answer_option_id" => 41,
              "answer" => "Brasília",
              "correct" => true,
              "answered_at" => "2026-09-05T18:19:12Z",
              "response_time_ms" => 1240
            }
          },
          "inserted_at" => "2026-09-05T18:20:00Z"
        }
      }
    },
    struct?: false,
    derive?: false
  )
end
