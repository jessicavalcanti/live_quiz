defmodule LiveQuizWeb.Api.V1.Schemas.GameHistoryResponse do
  @moduledoc "Schema for a paginated quiz game history."

  alias LiveQuizWeb.Api.V1.Schemas.GameSessionHistory
  alias LiveQuizWeb.Api.V1.Schemas.PaginationMeta
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "GameHistoryResponse",
      description: "Histórico paginado de partidas encerradas de um quiz.",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: GameSessionHistory},
        meta: PaginationMeta
      },
      required: [:data, :meta],
      example: %{
        "data" => [],
        "meta" => %{"page" => 1, "per_page" => 20, "total_entries" => 0, "total_pages" => 0}
      }
    },
    struct?: false,
    derive?: false
  )
end
