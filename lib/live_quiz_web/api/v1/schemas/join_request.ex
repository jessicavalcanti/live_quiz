defmodule LiveQuizWeb.Api.V1.Schemas.JoinRequest do
  @moduledoc """
  Documents the body accepted when entering a room.

  Only the nickname. Whether the participation is tied to an account is decided
  by the JWT the request carries, not by anything written here.
  """

  alias LiveQuiz.Games.Participant
  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "JoinRequest",
      description: "Corpo de entrada em uma sala.",
      type: :object,
      properties: %{
        nickname: %Schema{
          type: :string,
          description:
            "Apelido na sala. Letras, números, espaço, hífen e sublinhado; único na sala, sem diferenciar maiúsculas de minúsculas",
          minLength: Participant.nickname_min_length(),
          maxLength: Participant.nickname_max_length(),
          example: "Ana"
        }
      },
      required: [:nickname],
      example: %{"nickname" => "Ana"}
    },
    struct?: false,
    derive?: false
  )
end
