defmodule LiveQuizWeb.Api.V1.Schemas.GameSessionRequest do
  @moduledoc """
  Documents the body accepted when opening a room.

  Only the quiz is asked for. The host comes from the JWT, and the join code is
  drawn by the server: a code sent in the body is read by nobody.
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "GameSessionRequest",
      description: "Corpo de abertura de uma sala. O host vem do token, nunca do corpo.",
      type: :object,
      properties: %{
        quiz_id: %Schema{
          type: :integer,
          description: "Identificador do quiz que a sala vai jogar",
          example: 12
        }
      },
      required: [:quiz_id],
      example: %{"quiz_id" => 12}
    },
    struct?: false,
    derive?: false
  )
end
