defmodule LiveQuizWeb.Api.V1.Schemas.RefreshResponse do
  @moduledoc """
  Documents the pair of tokens issued by a refresh.

  The refresh token *is* reissued, and the presented one stops working: a
  session is a chain of single-use links, which is what lets the server see a
  replay and end the session (R03). A client that keeps the old token instead
  of storing this one is a client that logs its person out at the next renewal.
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "RefreshResponse",
      description:
        "Novo par de tokens emitido a partir de um refresh token. " <>
          "O refresh token enviado é gasto e deve ser substituído pelo novo.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          description: "Tokens renovados",
          properties: %{
            access_token: %Schema{
              type: :string,
              description: "Token de acesso, com validade de 15 minutos"
            },
            refresh_token: %Schema{
              type: :string,
              description:
                "Novo token de renovação, com validade de 30 dias. Substitui o token enviado, " <>
                  "que deixa de valer. Reapresentar o antigo encerra a sessão."
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
          required: [:access_token, :refresh_token, :token_type, :expires_in]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "access_token" => "eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9.acesso.assinatura",
          "refresh_token" => "eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9.renovacao.assinatura",
          "token_type" => "Bearer",
          "expires_in" => 900
        }
      }
    },
    struct?: false,
    derive?: false
  )
end
