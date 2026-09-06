defmodule LiveQuizWeb.Api.V1.Schemas.ParticipantResponse do
  @moduledoc """
  Documents the `data` envelope of a single participation, answered to the
  person it belongs to — which is why `user_id` is part of the example.
  """

  alias LiveQuizWeb.Api.V1.Schemas.Participant

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "ParticipantResponse",
      description: "Resposta com a participação que a credencial apresentada identifica.",
      type: :object,
      properties: %{data: Participant},
      required: [:data],
      example: %{
        "data" => %{
          "id" => 88,
          "nickname" => "Ana",
          "connected" => true,
          "joined_at" => "2026-08-31T14:05:00Z",
          "user_id" => nil
        }
      }
    },
    struct?: false,
    derive?: false
  )
end
