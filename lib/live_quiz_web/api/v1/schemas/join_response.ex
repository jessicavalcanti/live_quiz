defmodule LiveQuizWeb.Api.V1.Schemas.JoinResponse do
  @moduledoc """
  Documents the answer of entering a room — the one and only place in the whole
  API where the clear credential appears (AD-24).

  It is issued here and never reissued: no endpoint gives it back, and losing it
  is losing that participation. The description of the property says so, because
  a client that assumed otherwise would only find out when somebody was already
  locked out of a room they had paid a seat for.
  """

  alias LiveQuizWeb.Api.V1.Schemas.Participant
  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "JoinResponse",
      description: "Resposta de entrada em uma sala, com a participação e a credencial.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          description: "Participação criada e a credencial que a identifica",
          properties: %{
            participant: Participant,
            participant_token: %Schema{
              type: :string,
              description:
                "Credencial de participação, **devolvida uma única vez**. Não é reemitida por nenhum endpoint: guarde-a e envie-a em `Authorization: Participant <token>`. Perdê-la é perder a participação",
              example: "S0hBVkVSLU5BTy1QRVJTSVNUSURP"
            }
          },
          required: [:participant, :participant_token]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "participant" => %{
            "id" => 88,
            "nickname" => "Ana",
            "connected" => false,
            "joined_at" => "2026-08-31T14:05:00Z",
            "user_id" => nil
          },
          "participant_token" => "S0hBVkVSLU5BTy1QRVJTSVNUSURP"
        }
      }
    },
    struct?: false,
    derive?: false
  )
end
