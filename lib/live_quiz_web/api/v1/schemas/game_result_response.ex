defmodule LiveQuizWeb.Api.V1.Schemas.GameResultResponse do
  @moduledoc "Schema for one immutable game result."

  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "GameResultResponse",
      description: "Resultado imutável de um participante.",
      type: :object,
      properties: %{data: %Schema{type: :object}},
      required: [:data],
      example: %{"data" => %{"id" => 1, "score" => 900, "final_position" => 1}}
    },
    struct?: false,
    derive?: false
  )
end
