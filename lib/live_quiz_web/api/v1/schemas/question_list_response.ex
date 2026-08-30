defmodule LiveQuizWeb.Api.V1.Schemas.QuestionListResponse do
  @moduledoc """
  Documents the list of questions of a quiz.

  There is no `meta`: the endpoint is not paginated, because a quiz holds at
  most a few dozen questions.
  """

  alias LiveQuizWeb.Api.V1.Schemas.Question
  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "QuestionListResponse",
      description: "Perguntas do quiz, ordenadas por posição.",
      type: :object,
      properties: %{
        data: %Schema{type: :array, description: "Perguntas do quiz", items: Question}
      },
      required: [:data],
      example: %{
        "data" => [
          %{
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
        ]
      }
    },
    struct?: false,
    derive?: false
  )
end
