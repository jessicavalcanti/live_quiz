defmodule LiveQuizWeb.Api.V1.Schemas.MoveRequest do
  @moduledoc """
  Documents the body accepted when moving a question one place.
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "MoveRequest",
      description: "Corpo do movimento de uma pergunta, uma casa por vez.",
      type: :object,
      properties: %{
        direction: %Schema{
          type: :string,
          description: "Direção do movimento",
          enum: ["up", "down"]
        }
      },
      required: [:direction],
      example: %{"direction" => "down"}
    },
    struct?: false,
    derive?: false
  )
end
