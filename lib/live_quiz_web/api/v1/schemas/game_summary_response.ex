defmodule LiveQuizWeb.Api.V1.Schemas.GameSummaryResponse do
  @moduledoc """
  Documents what a match that has just been ended adds up to.

  `questions_played` is the position the match reached, which is the number of
  questions actually applied: a match finished on question 7 of 10 played seven.
  `answers_count` counts one answer per participation and question, so somebody
  who changed their mind counts once.
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "GameSummaryResponse",
      description: "Fechamento da partida: até onde ela foi e quanto foi respondido.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          description: "Fechamento da partida",
          properties: %{
            status: %Schema{
              type: :string,
              description: "Situação da partida",
              example: "finished"
            },
            finished_at: %Schema{
              type: :string,
              format: :"date-time",
              nullable: true,
              description: "Encerramento da partida, em ISO 8601 UTC"
            },
            question_count: %Schema{
              type: :integer,
              description: "Quantas perguntas a partida tem"
            },
            questions_played: %Schema{
              type: :integer,
              description: "Quantas perguntas chegaram a ser aplicadas"
            },
            answers_count: %Schema{
              type: :integer,
              description: "Respostas da partida inteira, uma por participação e pergunta"
            },
            participants_count: %Schema{
              type: :integer,
              description: "Participações ativas no encerramento"
            }
          },
          required: [
            :status,
            :finished_at,
            :question_count,
            :questions_played,
            :answers_count,
            :participants_count
          ]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "status" => "finished",
          "finished_at" => "2026-09-05T18:20:00Z",
          "question_count" => 10,
          "questions_played" => 10,
          "answers_count" => 220,
          "participants_count" => 25
        }
      }
    },
    struct?: false,
    derive?: false
  )
end
