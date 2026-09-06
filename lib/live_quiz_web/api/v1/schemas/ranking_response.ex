defmodule LiveQuizWeb.Api.V1.Schemas.RankingResponse do
  @moduledoc "Schema for a match ranking response."

  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "RankingResponse",
      description: "Ranking persistido da partida.",
      type: :object,
      properties: %{data: %Schema{type: :array, items: %Schema{type: :object}}},
      required: [:data],
      example: %{"data" => []}
    },
    struct?: false,
    derive?: false
  )
end
