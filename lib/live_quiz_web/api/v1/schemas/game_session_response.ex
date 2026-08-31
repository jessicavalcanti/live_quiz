defmodule LiveQuizWeb.Api.V1.Schemas.GameSessionResponse do
  @moduledoc """
  Documents the `data` envelope of a whole room.
  """

  alias LiveQuizWeb.Api.V1.Schemas.GameSession

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "GameSessionResponse",
      description: "Resposta com uma sala completa.",
      type: :object,
      properties: %{data: GameSession},
      required: [:data],
      example: %{
        "data" => %{
          "code" => "K7P4Q2",
          "status" => "waiting",
          "quiz_title" => "Geografia",
          "quiz_id" => 12,
          "reserved_slots" => 0,
          "max_participants" => 25,
          "connected_count" => 0,
          "started_at" => nil,
          "finished_at" => nil,
          "expires_at" => nil,
          "inserted_at" => "2026-08-31T14:02:11Z"
        }
      }
    },
    struct?: false,
    derive?: false
  )
end
