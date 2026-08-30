defmodule LiveQuizWeb.Api.V1.Schemas.RefreshResponse do
  @moduledoc """
  Documents the access token issued by a refresh.

  The refresh token is not reissued: the client keeps the one it already has
  until it expires.
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "RefreshResponse",
      description: "Novo token de acesso emitido a partir de um refresh token.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          description: "Token de acesso renovado",
          properties: %{
            access_token: %Schema{
              type: :string,
              description: "Token de acesso, com validade de 15 minutos"
            },
            token_type: %Schema{
              type: :string,
              description: "Esquema a usar no cabeçalho Authorization",
              example: "Bearer"
            },
            expires_in: %Schema{
              type: :integer,
              description: "Validade do token de acesso, em segundos"
            }
          },
          required: [:access_token, :token_type, :expires_in]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "access_token" => "eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9.acesso.assinatura",
          "token_type" => "Bearer",
          "expires_in" => 900
        }
      }
    },
    struct?: false,
    derive?: false
  )
end
