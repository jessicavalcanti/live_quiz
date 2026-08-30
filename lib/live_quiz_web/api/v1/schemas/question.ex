defmodule LiveQuizWeb.Api.V1.Schemas.Question do
  @moduledoc """
  Documents one question, with its answer options, as it is serialized by the
  API.
  """

  alias LiveQuizWeb.Api.V1.Schemas.AnswerOption
  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "Question",
      description: "Uma pergunta do quiz, sempre acompanhada das suas 4 alternativas.",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, description: "Identificador da pergunta"},
        text: %Schema{type: :string, description: "Enunciado da pergunta", maxLength: 500},
        position: %Schema{
          type: :integer,
          description: "Posição da pergunta no quiz, começando em 1",
          minimum: 1
        },
        answer_options: %Schema{
          type: :array,
          description: "As 4 alternativas, ordenadas por posição",
          items: AnswerOption
        }
      },
      required: [:id, :text, :position, :answer_options],
      example: %{
        "id" => 7,
        "text" => "Qual é a capital do Brasil?",
        "position" => 1,
        "answer_options" => [
          %{"id" => 10, "text" => "Rio de Janeiro", "position" => 1, "is_correct" => false},
          %{"id" => 11, "text" => "São Paulo", "position" => 2, "is_correct" => false},
          %{"id" => 12, "text" => "Brasília", "position" => 3, "is_correct" => true},
          %{"id" => 13, "text" => "Salvador", "position" => 4, "is_correct" => false}
        ]
      }
    },
    struct?: false,
    derive?: false
  )
end
