defmodule LiveQuizWeb.Api.V1.Schemas.NextRequest do
  @moduledoc """
  Documents the body required to advance a match one question.

  `expected_position` is the position the client believes is current, and it is
  required rather than optional (AD-44): a command that does not say where it
  thinks the match is loses the only protection there is against two advances
  crossing each other, and the API is not allowed to be more fragile than the
  web. Before the first question there is no position yet, which is what `null`
  says — the very value `question_number` has in the state at that moment.
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "NextRequest",
      description: "Corpo do avanço de pergunta, com a posição que o cliente julga corrente.",
      type: :object,
      properties: %{
        expected_position: %Schema{
          type: :integer,
          minimum: 1,
          nullable: true,
          description:
            "Posição da pergunta atual, ou `null` antes da primeira. Divergiu, a resposta é 409 `stale`",
          example: 1
        }
      },
      required: [:expected_position],
      example: %{"expected_position" => 1}
    },
    struct?: false,
    derive?: false
  )
end
