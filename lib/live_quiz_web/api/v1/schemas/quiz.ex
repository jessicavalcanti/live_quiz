defmodule LiveQuizWeb.Api.V1.Schemas.Quiz do
  @moduledoc """
  Documents one quiz as it is serialized by the API.

  `questions` is absent from the listing and from a freshly created quiz — the
  payload never lies with an empty list — so it is not a required property.
  """

  alias LiveQuizWeb.Api.V1.Schemas.Question
  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "Quiz",
      description: "Um quiz do usuário autenticado.",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, description: "Identificador do quiz"},
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
        },
        questions_count: %Schema{type: :integer, description: "Quantidade de perguntas do quiz"},
        playable: %Schema{
          type: :boolean,
          description: "Indica se o quiz já tem pelo menos uma pergunta e pode ser jogado"
        },
        inserted_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Data de criação, em ISO 8601 UTC"
        },
        updated_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Data da última atualização, em ISO 8601 UTC"
        },
        questions: %Schema{
          type: :array,
          description:
            "Perguntas do quiz, ordenadas por posição. Presente apenas no detalhe do quiz",
          items: Question
        }
      },
      required: [
        :id,
        :title,
        :description,
        :questions_count,
        :playable,
        :inserted_at,
        :updated_at
      ],
      example: %{
        "id" => 1,
        "title" => "Geografia",
        "description" => "Capitais do mundo",
        "questions_count" => 3,
        "playable" => true,
        "inserted_at" => "2026-08-30T18:00:00Z",
        "updated_at" => "2026-08-30T18:30:00Z"
      }
    },
    struct?: false,
    derive?: false
  )
end
