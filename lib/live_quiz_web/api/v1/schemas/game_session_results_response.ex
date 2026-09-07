defmodule LiveQuizWeb.Api.V1.Schemas.GameSessionResultsResponse do
  @moduledoc """
  Schema for the complete result of one match.

  Not the same shape as a paginated listing, which is what it used to be
  documented as: `data` here is the match plus everybody's results, while
  `GameResultListResponse` says `data` is an array of results and carries a
  `meta` this endpoint has no page to describe. A generated client built from
  the old declaration could not read this body at all (R33).
  """

  alias LiveQuizWeb.Api.V1.Schemas.GameResult
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "GameSessionResultsResponse",
      description: "A partida encerrada e o resultado de cada participação.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            session: %Schema{
              type: :object,
              properties: %{
                id: %Schema{type: :integer},
                code: %Schema{type: :string},
                quiz_id: %Schema{
                  type: :integer,
                  nullable: true,
                  description: "Nulo quando o quiz de origem foi excluído"
                },
                quiz_title: %Schema{type: :string},
                status: %Schema{type: :string, enum: ["finished"]},
                finished_at: %Schema{type: :string, format: :"date-time", nullable: true}
              },
              required: [:id, :code, :quiz_title, :status, :finished_at]
            },
            results: %Schema{type: :array, items: GameResult}
          },
          required: [:session, :results]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "session" => %{
            "id" => 12,
            "code" => "K7P4Q2",
            "quiz_id" => 7,
            "quiz_title" => "Geografia",
            "status" => "finished",
            "finished_at" => "2026-09-05T18:20:00Z"
          },
          "results" => []
        }
      }
    },
    struct?: false,
    derive?: false
  )
end
