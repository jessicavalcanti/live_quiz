defmodule LiveQuizWeb.Api.V1.Schemas.SessionResponse do
  @moduledoc """
  Documents the pair of tokens issued at login, alongside the basic user data.
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "SessionResponse",
      description: "Par de tokens emitido no login e os dados básicos do usuário.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          description: "Tokens da sessão",
          properties: %{
            access_token: %Schema{
              type: :string,
              description: "Token de acesso, com validade de 15 minutos"
            },
            refresh_token: %Schema{
              type: :string,
              description: "Token de renovação, com validade de 30 dias"
            },
            token_type: %Schema{
              type: :string,
              description: "Esquema a usar no cabeçalho Authorization",
              example: "Bearer"
            },
            expires_in: %Schema{
              type: :integer,
              description: "Validade do token de acesso, em segundos"
            },
            user: %Schema{
              type: :object,
              description: "Dados básicos do usuário autenticado",
              properties: %{
                id: %Schema{type: :integer, description: "Identificador do usuário"},
                name: %Schema{type: :string, description: "Nome do usuário"},
                email: %Schema{type: :string, format: :email, description: "E-mail do usuário"}
              },
              required: [:id, :name, :email]
            }
          },
          required: [:access_token, :refresh_token, :token_type, :expires_in, :user]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "access_token" => "eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9.acesso.assinatura",
          "refresh_token" => "eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9.renovacao.assinatura",
          "token_type" => "Bearer",
          "expires_in" => 900,
          "user" => %{"id" => 1, "name" => "Maria", "email" => "voce@example.com"}
        }
      }
    },
    struct?: false,
    derive?: false
  )
end
