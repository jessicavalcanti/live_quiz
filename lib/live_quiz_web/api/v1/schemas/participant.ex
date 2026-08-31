defmodule LiveQuizWeb.Api.V1.Schemas.Participant do
  @moduledoc """
  Documents one participation as the API serializes it.

  `user_id` is not a required property because it only appears when the room is
  answering somebody about their own participation. Taking part with an account
  is not something the rest of the lobby gets to learn, so the listing leaves it
  out entirely instead of sending it as `null`.

  The access credential is in no shape of this schema. It exists in clear
  exactly once, in the answer of the join endpoint, and `JoinResponse` is the
  only place that documents it.
  """

  alias LiveQuiz.Games.Participant, as: Person
  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "Participant",
      description: "Uma participação em uma sala, com ou sem conta.",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, description: "Identificador da participação"},
        nickname: %Schema{
          type: :string,
          description: "Apelido escolhido, como foi digitado",
          minLength: Person.nickname_min_length(),
          maxLength: Person.nickname_max_length(),
          example: "Ana"
        },
        connected: %Schema{
          type: :boolean,
          description:
            "Indica se a participação está conectada neste instante. Um cliente REST não mantém conexão: o campo reflete a presença aberta em outro lugar, como o navegador"
        },
        joined_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Entrada na sala, em ISO 8601 UTC"
        },
        user_id: %Schema{
          type: :integer,
          description:
            "Conta vinculada à participação, nula para quem entrou sem conta. Presente apenas quando a resposta é sobre a própria participação",
          nullable: true
        }
      },
      required: [:id, :nickname, :connected, :joined_at],
      example: %{
        "id" => 88,
        "nickname" => "Ana",
        "connected" => true,
        "joined_at" => "2026-08-31T14:05:00Z"
      }
    },
    struct?: false,
    derive?: false
  )
end
