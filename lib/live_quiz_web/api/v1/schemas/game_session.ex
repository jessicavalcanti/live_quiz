defmodule LiveQuizWeb.Api.V1.Schemas.GameSession do
  @moduledoc """
  Documents a room as it is serialized for whoever is entitled to the whole of
  it: the host who owns it, or the client that just opened it.

  The restricted read that anybody may do is a different schema
  (`GameSessionPublic`), not this one with optional fields — the privacy of
  AD-35 is a decision the contract has to state, not hide behind a property that
  happens to be missing.

  `participants` is absent from every read but the host's lobby, so it is not a
  required property: the payload never invents an empty list for a room whose
  people were simply not asked for.
  """

  alias LiveQuiz.Games.GameSession, as: Room
  alias LiveQuizWeb.Api.V1.Schemas.Participant
  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "GameSession",
      description: "Uma sala completa, como o host a enxerga.",
      type: :object,
      properties: %{
        code: %Schema{
          type: :string,
          description: "Código de acesso da sala, usado no lugar do identificador",
          pattern: "^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{6}$",
          example: "K7P4Q2"
        },
        status: %Schema{
          type: :string,
          description:
            "Situação da sala. A fase 2 usa `waiting`, `in_progress`, `cancelled` e `expired`; `finished` fica reservado à execução do quiz",
          enum: Enum.map(Room.statuses(), &Atom.to_string/1),
          example: "waiting"
        },
        quiz_title: %Schema{
          type: :string,
          description:
            "Título do quiz no momento em que a sala foi aberta. Continua legível mesmo se o quiz for excluído depois"
        },
        quiz_id: %Schema{
          type: :integer,
          description: "Identificador do quiz de origem, nulo se o quiz tiver sido excluído",
          nullable: true
        },
        reserved_slots: %Schema{
          type: :integer,
          description:
            "Vagas ocupadas. Conta toda participação já criada, inclusive de quem saiu: sair não devolve o assento",
          minimum: 0
        },
        max_participants: %Schema{
          type: :integer,
          description: "Capacidade máxima da sala"
        },
        connected_count: %Schema{
          type: :integer,
          description: "Quantas participações estão conectadas neste instante",
          minimum: 0
        },
        started_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Início da partida, em ISO 8601 UTC. Nulo enquanto a sala espera",
          nullable: true
        },
        finished_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Encerramento da sala, em ISO 8601 UTC. Nulo enquanto ela estiver ativa",
          nullable: true
        },
        expires_at: %Schema{
          type: :string,
          format: :"date-time",
          description:
            "Prazo de expiração por ausência do host, em ISO 8601 UTC. Nulo enquanto o host estiver presente",
          nullable: true
        },
        inserted_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Data de criação da sala, em ISO 8601 UTC"
        },
        participants: %Schema{
          type: :array,
          description: "Lobby da sala. Presente apenas na leitura do host",
          items: Participant
        }
      },
      required: [
        :code,
        :status,
        :quiz_title,
        :quiz_id,
        :reserved_slots,
        :max_participants,
        :connected_count,
        :started_at,
        :finished_at,
        :expires_at,
        :inserted_at
      ],
      example: %{
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
    },
    struct?: false,
    derive?: false
  )
end
