defmodule LiveQuizWeb.Api.V1.Schemas.PaginationMeta do
  @moduledoc """
  Documents the `meta` object that travels alongside every paginated listing.
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "PaginationMeta",
      description: "Metadados de paginação de uma listagem.",
      type: :object,
      properties: %{
        page: %Schema{type: :integer, description: "Página atual", minimum: 1},
        per_page: %Schema{
          type: :integer,
          description: "Itens por página",
          minimum: 1,
          maximum: 100
        },
        total_entries: %Schema{type: :integer, description: "Total de itens encontrados"},
        total_pages: %Schema{type: :integer, description: "Total de páginas"}
      },
      required: [:page, :per_page, :total_entries, :total_pages],
      example: %{
        "page" => 1,
        "per_page" => 20,
        "total_entries" => 42,
        "total_pages" => 3
      }
    },
    struct?: false,
    derive?: false
  )
end
