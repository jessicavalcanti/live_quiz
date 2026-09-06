defmodule LiveQuizWeb.Api.V1.Schemas.UserResponse do
  @moduledoc """
  Documents the authenticated user returned by `GET /api/v1/me`.
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "UserResponse",
      description: "Dados do usuário dono do token.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          description: "Usuário autenticado",
          properties: %{
            id: %Schema{type: :integer, description: "Identificador do usuário"},
            name: %Schema{type: :string, description: "Nome do usuário"},
            email: %Schema{type: :string, format: :email, description: "E-mail do usuário"},
            confirmed: %Schema{
              type: :boolean,
              description: "Indica se o e-mail do usuário já foi confirmado"
            }
          },
          required: [:id, :name, :email, :confirmed]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "id" => 1,
          "name" => "Maria",
          "email" => "voce@example.com",
          "confirmed" => true
        }
      }
    },
    struct?: false,
    derive?: false
  )
end
