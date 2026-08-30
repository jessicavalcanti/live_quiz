defmodule LiveQuizWeb.Api.V1.Schemas.QuizRequest do
  @moduledoc """
  Documents the body accepted when creating or updating a quiz.

  The owner is never part of the body: it comes from the JWT.
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "QuizRequest",
      description: "Corpo de criação ou atualização de um quiz.",
      type: :object,
      properties: %{
        quiz: %Schema{
          type: :object,
          description: "Atributos editáveis do quiz",
          properties: %{
            title: %Schema{
              type: :string,
              description: "Título do quiz",
              minLength: 3,
              maxLength: 120
            },
            description: %Schema{
              type: :string,
              description: "Descrição do quiz",
              maxLength: 500,
              nullable: true
            }
          },
          required: [:title]
        }
      },
      required: [:quiz],
      example: %{"quiz" => %{"title" => "Geografia", "description" => "Capitais do mundo"}}
    },
    struct?: false,
    derive?: false
  )
end
