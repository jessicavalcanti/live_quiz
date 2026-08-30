defmodule LiveQuizWeb.Api.V1.Schemas.ValidationErrorResponse do
  @moduledoc """
  Documents the error envelope of an invalid changeset: `errors` maps each
  rejected field to the list of messages already translated to pt-BR.
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "ValidationErrorResponse",
      description: "Erros de validação, agrupados por campo e já traduzidos para pt-BR.",
      type: :object,
      properties: %{
        errors: %Schema{
          type: :object,
          description: "Mapa de campo para as mensagens que ele violou",
          additionalProperties: %Schema{
            type: :array,
            description: "Mensagens do campo",
            items: %Schema{type: :string}
          }
        }
      },
      required: [:errors],
      example: %{
        "errors" => %{
          "title" => ["não pode ficar em branco"],
          "answer_options" => ["a pergunta deve ter exatamente 4 alternativas"]
        }
      }
    },
    struct?: false,
    derive?: false
  )
end
