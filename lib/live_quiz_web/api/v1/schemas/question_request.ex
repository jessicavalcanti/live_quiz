defmodule LiveQuizWeb.Api.V1.Schemas.QuestionRequest do
  @moduledoc """
  Documents the body accepted when creating or updating a question.

  The position is never part of the body: on creation it is computed by the
  context, and changing it is what the `move` endpoint is for. On update each
  answer option must carry its `id`, so the stored rows are updated instead of
  replaced.
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "QuestionRequest",
      description: "Corpo de criação ou atualização de uma pergunta com as suas 4 alternativas.",
      type: :object,
      properties: %{
        question: %Schema{
          type: :object,
          description: "Atributos editáveis da pergunta",
          properties: %{
            text: %Schema{
              type: :string,
              description: "Enunciado da pergunta",
              minLength: 3,
              maxLength: 500
            },
            answer_options: %Schema{
              type: :array,
              description:
                "Exatamente 4 alternativas, com posições de 1 a 4 e uma única correta. " <>
                  "Na atualização, cada alternativa deve trazer o seu id",
              minItems: 4,
              maxItems: 4,
              items: %Schema{
                type: :object,
                description: "Alternativa enviada pelo cliente",
                properties: %{
                  id: %Schema{
                    type: :integer,
                    description: "Id da alternativa existente, obrigatório na atualização"
                  },
                  text: %Schema{
                    type: :string,
                    description: "Texto da alternativa",
                    minLength: 1,
                    maxLength: 200
                  },
                  position: %Schema{
                    type: :integer,
                    description: "Posição da alternativa, de 1 a 4",
                    minimum: 1,
                    maximum: 4
                  },
                  is_correct: %Schema{
                    type: :boolean,
                    description: "Indica se esta é a alternativa correta"
                  }
                },
                required: [:text, :position, :is_correct]
              }
            }
          },
          required: [:text, :answer_options]
        }
      },
      required: [:question],
      example: %{
        "question" => %{
          "text" => "Qual é a capital do Brasil?",
          "answer_options" => [
            %{"text" => "Rio de Janeiro", "position" => 1, "is_correct" => false},
            %{"text" => "São Paulo", "position" => 2, "is_correct" => false},
            %{"text" => "Brasília", "position" => 3, "is_correct" => true},
            %{"text" => "Salvador", "position" => 4, "is_correct" => false}
          ]
        }
      }
    },
    struct?: false,
    derive?: false
  )
end
