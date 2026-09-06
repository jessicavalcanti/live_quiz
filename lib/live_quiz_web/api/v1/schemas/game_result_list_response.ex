defmodule LiveQuizWeb.Api.V1.Schemas.GameResultListResponse do
  @moduledoc "Schema for a paginated result or match history."

  alias LiveQuizWeb.Api.V1.Schemas.PaginationMeta
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "GameResultListResponse",
      description: "Resultados ou partidas de um histórico paginado.",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: %Schema{type: :object}},
        meta: PaginationMeta
      },
      required: [:data],
      example: %{
        "data" => [],
        "meta" => %{"page" => 1, "per_page" => 20, "total_entries" => 0, "total_pages" => 0}
      }
    },
    struct?: false,
    derive?: false
  )
end
