defmodule LiveQuizWeb.Api.V1.Schemas.SubmittedAnswerResponse do
  @moduledoc """
  Documents the answer a participant just recorded.

  `question_closed` is the one thing the answer says about the match: it is true
  when this very answer was the last one missing and closed the question in the
  same transaction (AD-42). A client that reads it knows to ask for the tally
  instead of waiting for a deadline that will never arrive.

  Sending another alternative while the question is open answers `201` again and
  keeps a single row: changing one's mind is part of playing (AD-41).
  """

  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "SubmittedAnswerResponse",
      description: "Resposta registrada de um participante à pergunta aberta.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          description: "Resposta registrada",
          properties: %{
            answer_option_id: %Schema{
              type: :integer,
              description: "Alternativa que ficou registrada"
            },
            answered_at: %Schema{
              type: :string,
              format: :"date-time",
              description: "Instante da escolha que valeu, em ISO 8601 UTC"
            },
            question_closed: %Schema{
              type: :boolean,
              description: "Se esta resposta foi a última que faltava e encerrou a pergunta"
            }
          },
          required: [:answer_option_id, :answered_at, :question_closed]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "answer_option_id" => 42,
          "answered_at" => "2026-09-05T18:04:12.482913Z",
          "question_closed" => false
        }
      }
    },
    struct?: false,
    derive?: false
  )
end
