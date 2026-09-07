defmodule LiveQuizWeb.Api.V1.Schemas.GameResult do
  @moduledoc "Schema for an immutable participant result."

  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "GameResult",
      description: "Resultado imutável de uma participação em uma partida encerrada.",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        game_session_id: %Schema{type: :integer},
        participant_id: %Schema{type: :integer},
        user_id: %Schema{type: :integer, nullable: true},
        quiz_id: %Schema{type: :integer},
        quiz_title: %Schema{type: :string},
        nickname: %Schema{type: :string},
        score: %Schema{type: :integer},
        correct_answers: %Schema{type: :integer},
        incorrect_answers: %Schema{type: :integer},
        unanswered_questions: %Schema{
          type: :integer,
          description: "Perguntas aplicadas que esta participação não respondeu"
        },
        answered_questions: %Schema{type: :integer},
        played_questions: %Schema{
          type: :integer,
          description:
            "Perguntas que a partida chegou a aplicar. " <>
              "Sempre igual a answered_questions + unanswered_questions"
        },
        total_questions: %Schema{
          type: :integer,
          description:
            "Perguntas congeladas no snapshot da partida. " <>
              "Maior que played_questions quando a partida terminou antes do fim"
        },
        total_response_time_ms: %Schema{type: :integer},
        average_response_time_ms: %Schema{type: :number, nullable: true},
        final_position: %Schema{type: :integer},
        question_results: %Schema{type: :array, items: %Schema{type: :object}},
        inserted_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [
        :id,
        :game_session_id,
        :participant_id,
        :quiz_id,
        :quiz_title,
        :nickname,
        :score,
        :correct_answers,
        :incorrect_answers,
        :unanswered_questions,
        :answered_questions,
        :played_questions,
        :total_questions,
        :total_response_time_ms,
        :final_position,
        :question_results,
        :inserted_at
      ],
      example: %{
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
        "question_results" => [],
        "inserted_at" => "2026-09-05T18:20:00Z"
      }
    },
    struct?: false,
    derive?: false
  )
end
