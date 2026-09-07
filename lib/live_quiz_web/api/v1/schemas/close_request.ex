defmodule LiveQuizWeb.Api.V1.Schemas.CloseRequest do
  @moduledoc """
  Documents the optional body of closing a question.

  Unlike `NextRequest`, `expected_position` is optional here. Advancing has
  always required it; closing never carried it, and clients written against
  that contract keep working — a body left out means "close whatever is
  current", exactly as before.

  Sending it is what buys the protection: the lock serializes two commands but
  says nothing about which question each one meant, so a retry aimed at
  question 1 that arrives after the host advanced used to close question 2.
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "CloseRequest",
      description: "Corpo opcional do encerramento, com a pergunta a que o comando se destina.",
      type: :object,
      properties: %{
        expected_position: %Schema{
          type: :integer,
          minimum: 1,
          nullable: true,
          description:
            "Pergunta a que o comando se destina. Divergiu da corrente, a resposta é 409 `stale`; omitida, encerra a corrente",
          example: 1
        }
      },
      required: [],
      example: %{"expected_position" => 1}
    },
    struct?: false,
    derive?: false
  )
end
