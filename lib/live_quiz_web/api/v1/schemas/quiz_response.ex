defmodule LiveQuizWeb.Api.V1.Schemas.QuizResponse do
  @moduledoc """
  Documents the `data` envelope of a single quiz.
  """

  alias LiveQuizWeb.Api.V1.Schemas.Quiz

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "QuizResponse",
      description: "Resposta com um único quiz.",
      type: :object,
      properties: %{data: Quiz},
      required: [:data],
      example: %{
        "data" => %{
          "id" => 1,
          "title" => "Geografia",
          "description" => "Capitais do mundo",
          "questions_count" => 0,
          "playable" => false,
          "inserted_at" => "2026-08-30T18:00:00Z",
          "updated_at" => "2026-08-30T18:00:00Z"
        }
      }
    },
    struct?: false,
    derive?: false
  )
end
