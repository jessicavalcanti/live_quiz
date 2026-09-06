defmodule LiveQuizWeb.Api.V1.Schemas.ErrorResponse do
  @moduledoc """
  Documents the error envelope used by every failure that does not belong to a
  field: `%{errors: %{detail: "..."}}`.

  The refusals of a running match carry a `code` besides the message. It is the
  half of the envelope a client is meant to branch on — "corrigir o payload" is
  not the same reaction as "reconsultar o estado" — while the message is the
  half written for a person and free to change. It is optional because the
  refusals of the earlier phases answer with the message alone.
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
            detail: %Schema{type: :string, description: "Mensagem do erro, em pt-BR"},
            code: %Schema{
              type: :string,
              description:
                "Código estável do motivo, em inglês. Presente nas recusas da execução da partida",
              example: "time_is_up"
            }
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
