defmodule LiveQuizWeb.Api.V1.Schemas.GameSessionPublicResponse do
  @moduledoc """
  Documents the `data` envelope of the restricted read of a room.
  """

  alias LiveQuizWeb.Api.V1.Schemas.GameSessionPublic

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "GameSessionPublicResponse",
      description: "Resposta com a leitura pública de uma sala.",
      type: :object,
      properties: %{data: GameSessionPublic},
      required: [:data],
      example: %{
        "data" => %{
          "code" => "K7P4Q2",
          "quiz_title" => "Geografia",
          "status" => "waiting",
          "available" => true
        }
      }
    },
    struct?: false,
    derive?: false
  )
end
