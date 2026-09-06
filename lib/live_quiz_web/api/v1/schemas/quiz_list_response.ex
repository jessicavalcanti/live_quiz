defmodule LiveQuizWeb.Api.V1.Schemas.QuizListResponse do
  @moduledoc """
  Documents a page of quizzes: the entries in `data`, the pagination in `meta`.
  """

  alias LiveQuizWeb.Api.V1.Schemas.PaginationMeta
  alias LiveQuizWeb.Api.V1.Schemas.Quiz
  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "QuizListResponse",
      description: "Página de quizzes do usuário autenticado.",
      type: :object,
      properties: %{
        data: %Schema{type: :array, description: "Quizzes da página", items: Quiz},
        meta: PaginationMeta
      },
      required: [:data, :meta],
      example: %{
        "data" => [
          %{
            "id" => 1,
            "title" => "Geografia",
            "description" => "Capitais do mundo",
            "questions_count" => 3,
            "playable" => true,
            "inserted_at" => "2026-08-30T18:00:00Z",
            "updated_at" => "2026-08-30T18:30:00Z"
          }
        ],
        "meta" => %{
          "page" => 1,
          "per_page" => 20,
          "total_entries" => 1,
          "total_pages" => 1
        }
      }
    },
    struct?: false,
    derive?: false
  )
end
