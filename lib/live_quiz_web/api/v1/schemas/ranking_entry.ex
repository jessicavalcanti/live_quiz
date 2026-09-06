defmodule LiveQuizWeb.Api.V1.Schemas.RankingEntry do
  @moduledoc "Schema for one entry in a match ranking."

  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "RankingEntry",
      description: "Classificação de uma participação na partida.",
      type: :object,
      properties: %{
        participant_id: %Schema{type: :integer, description: "Identificador da participação"},
        nickname: %Schema{type: :string, description: "Apelido exibido"},
        score: %Schema{type: :integer, description: "Pontuação acumulada"},
        correct_answers: %Schema{type: :integer, description: "Respostas corretas"},
        incorrect_answers: %Schema{type: :integer, description: "Respostas incorretas"},
        total_response_time_ms: %Schema{
          type: :integer,
          description: "Tempo total de resposta em milissegundos"
        },
        position: %Schema{type: :integer, description: "Posição atual no ranking"}
      },
      required: [
        :participant_id,
        :nickname,
        :score,
        :correct_answers,
        :incorrect_answers,
        :total_response_time_ms,
        :position
      ],
      example: %{
        "participant_id" => 88,
        "nickname" => "Ana",
        "score" => 900,
        "correct_answers" => 9,
        "incorrect_answers" => 1,
        "total_response_time_ms" => 12_400,
        "position" => 1
      }
    },
    struct?: false,
    derive?: false
  )
end
