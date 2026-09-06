defmodule LiveQuizWeb.Api.V1.Schemas.QuestionResponse do
  @moduledoc """
  Documents the `data` envelope of a single question.
  """

  alias LiveQuizWeb.Api.V1.Schemas.Question

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "QuestionResponse",
      description: "Resposta com uma única pergunta.",
      type: :object,
      properties: %{data: Question},
      required: [:data],
      example: %{
        "data" => %{
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
      }
    },
    struct?: false,
    derive?: false
  )
end
