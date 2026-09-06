defmodule LiveQuizWeb.Api.V1.Schemas.AnswerRequest do
  @moduledoc """
  Documents the body accepted when a participant answers the open question.

  Only the alternative is asked for. Who is answering comes from the credential
  and which question is being answered comes from the match, so neither is read
  from the body: an alternative of another question is refused with 422 instead
  of quietly landing somewhere else.
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "AnswerRequest",
      description: "Corpo da resposta de um participante à pergunta aberta.",
      type: :object,
      properties: %{
        answer_option_id: %Schema{
          type: :integer,
          description: "Identificador da alternativa escolhida, dentre as da pergunta aberta",
          example: 42
        }
      },
      required: [:answer_option_id],
      example: %{"answer_option_id" => 42}
    },
    struct?: false,
    derive?: false
  )
end
