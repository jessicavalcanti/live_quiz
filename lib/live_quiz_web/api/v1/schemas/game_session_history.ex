defmodule LiveQuizWeb.Api.V1.Schemas.GameSessionHistory do
  @moduledoc "Schema for one entry in a quiz game history."

  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "GameSessionHistory",
      description: "Resumo de uma partida encerrada no histórico do quiz.",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        code: %Schema{type: :string, description: "Código da partida"},
        quiz_id: %Schema{
          type: :integer,
          nullable: true,
          description: "Nulo quando o quiz de origem foi excluído"
        },
        quiz_title: %Schema{type: :string},
        status: %Schema{
          type: :string,
          enum: ["finished"],
          description:
            "O histórico lista apenas partidas encerradas; uma sala cancelada não entra"
        },
        finished_at: %Schema{type: :string, format: :"date-time", nullable: true},
        participants_count: %Schema{type: :integer},
        winner_nickname: %Schema{type: :string, nullable: true},
        winner_score: %Schema{type: :integer, nullable: true}
      },
      required: [
        :id,
        :code,
        :quiz_id,
        :quiz_title,
        :status,
        :finished_at,
        :participants_count,
        :winner_nickname,
        :winner_score
      ],
      example: %{
        "id" => 12,
        "code" => "K7P4Q2",
        "quiz_id" => 7,
        "quiz_title" => "Geografia",
        "status" => "finished",
        "finished_at" => "2026-09-05T18:20:00Z",
        "participants_count" => 25,
        "winner_nickname" => "Ana",
        "winner_score" => 900
      }
    },
    struct?: false,
    derive?: false
  )
end
