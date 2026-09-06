defmodule LiveQuizWeb.Api.V1.Schemas.ParticipantListResponse do
  @moduledoc """
  Documents the lobby list of a room.

  There is no `meta`: the listing is not paginated, because a room holds at most
  25 people. The items leave `user_id` out — the list is what the room says
  about somebody to everybody else in it.
  """

  alias LiveQuizWeb.Api.V1.Schemas.Participant
  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "ParticipantListResponse",
      description: "Participações da sala, da mais antiga para a mais recente.",
      type: :object,
      properties: %{
        data: %Schema{type: :array, description: "Lobby da sala", items: Participant}
      },
      required: [:data],
      example: %{
        "data" => [
          %{
            "id" => 88,
            "nickname" => "Ana",
            "connected" => true,
            "joined_at" => "2026-08-31T14:05:00Z"
          },
          %{
            "id" => 89,
            "nickname" => "Bruno",
            "connected" => false,
            "joined_at" => "2026-08-31T14:06:30Z"
          }
        ]
      }
    },
    struct?: false,
    derive?: false
  )
end
