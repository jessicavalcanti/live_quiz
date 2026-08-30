defmodule LiveQuizWeb.Api.V1.Schemas.AnswerOption do
  @moduledoc """
  Documents one answer option as it is serialized by the API.

  The schema mirrors `LiveQuizWeb.Api.V1.QuestionJSON`, which is the single
  source of this payload.
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "AnswerOption",
      description: "Uma das quatro alternativas de uma pergunta.",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, description: "Identificador da alternativa"},
        text: %Schema{type: :string, description: "Texto da alternativa", maxLength: 200},
        position: %Schema{
          type: :integer,
          description: "Posição da alternativa dentro da pergunta, de 1 a 4",
          minimum: 1,
          maximum: 4
        },
        is_correct: %Schema{
          type: :boolean,
          description: "Indica se esta é a alternativa correta da pergunta"
        }
      },
      required: [:id, :text, :position, :is_correct],
      example: %{
        "id" => 12,
        "text" => "Brasília",
        "position" => 3,
        "is_correct" => true
      }
    },
    struct?: false,
    derive?: false
  )
end
