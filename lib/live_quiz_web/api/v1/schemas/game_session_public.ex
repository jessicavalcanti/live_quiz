defmodule LiveQuizWeb.Api.V1.Schemas.GameSessionPublic do
  @moduledoc """
  Documents what a room tells somebody who has not entered it yet.

  A schema of its own rather than `GameSession` with optional properties: what
  is missing here is missing on purpose (AD-35), and a contract that expressed
  that as "these fields may not come" would let a client keep asking for them.

  There is nothing about the people inside — not the list, and not a count
  either. `available` is the whole answer to "can I still get in", and a room one
  seat from full is as available as an empty one.
  """

  alias LiveQuiz.Games.GameSession, as: Room
  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "GameSessionPublic",
      description: "Leitura pública de uma sala, restrita ao que quem está de fora pode saber.",
      type: :object,
      properties: %{
        code: %Schema{
          type: :string,
          description: "Código de acesso da sala",
          pattern: "^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{6}$",
          example: "K7P4Q2"
        },
        quiz_title: %Schema{type: :string, description: "Título do quiz da sala"},
        status: %Schema{
          type: :string,
          description: "Situação da sala",
          enum: Enum.map(Room.statuses(), &Atom.to_string/1),
          example: "waiting"
        },
        available: %Schema{
          type: :boolean,
          description:
            "Indica se a sala ainda aceita gente: está esperando e tem vaga. Não revela quantas"
        }
      },
      required: [:code, :quiz_title, :status, :available],
      example: %{
        "code" => "K7P4Q2",
        "quiz_title" => "Geografia",
        "status" => "waiting",
        "available" => true
      }
    },
    struct?: false,
    derive?: false
  )
end
