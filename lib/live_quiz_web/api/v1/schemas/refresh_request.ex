defmodule LiveQuizWeb.Api.V1.Schemas.RefreshRequest do
  @moduledoc """
  Documents the body that exchanges a refresh token for a new access token.
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "RefreshRequest",
      description: "Refresh token emitido no login.",
      type: :object,
      properties: %{
        refresh_token: %Schema{
          type: :string,
          description: "Refresh token válido, com validade de 30 dias"
        }
      },
      required: [:refresh_token],
      example: %{"refresh_token" => "eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9.exemplo.assinatura"}
    },
    struct?: false,
    derive?: false
  )
end
