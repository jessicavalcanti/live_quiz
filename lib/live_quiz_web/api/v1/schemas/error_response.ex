defmodule LiveQuizWeb.Api.V1.Schemas.ErrorResponse do
  @moduledoc """
  Documents the error envelope used by every failure that does not belong to a
  field: `%{errors: %{detail: "..."}}`.
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "ErrorResponse",
      description: "Erro que não pertence a um campo, com uma mensagem legível em pt-BR.",
      type: :object,
      properties: %{
        errors: %Schema{
          type: :object,
          description: "Envelope de erro da API",
          properties: %{
            detail: %Schema{type: :string, description: "Mensagem do erro"}
          },
          required: [:detail]
        }
      },
      required: [:errors],
      example: %{"errors" => %{"detail" => "Não encontrado"}}
    },
    struct?: false,
    derive?: false
  )
end
