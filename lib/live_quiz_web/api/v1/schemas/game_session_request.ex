defmodule LiveQuizWeb.Api.V1.Schemas.GameSessionRequest do
  @moduledoc """
  Documents the body accepted when opening a room.

  The quiz is required and the duration of the questions is not. The host comes
  from the JWT and the join code is drawn by the server: neither is read from
  the body, whatever it carries.

  The duration is settled here, when the room opens, and not when the match
  starts (AD-38), so the lobby can already announce the pace to whoever walks
  in — and so it stops being changeable the moment the match begins.
  """

  alias LiveQuiz.Games.GameSession
  alias OpenApiSpex.Schema

  require OpenApiSpex

  OpenApiSpex.schema(
    %{
      title: "GameSessionRequest",
      description: "Corpo de abertura de uma sala. O host vem do token, nunca do corpo.",
      type: :object,
      properties: %{
        quiz_id: %Schema{
          type: :integer,
          description: "Identificador do quiz que a sala vai jogar",
          example: 12
        },
        question_duration_seconds: %Schema{
          type: :integer,
          description:
            "Tempo de cada pergunta, em segundos. Opcional, vale para a partida inteira e não muda depois do início",
          enum: GameSession.question_durations(),
          default: %GameSession{}.question_duration_seconds,
          example: 30
        }
      },
      required: [:quiz_id],
      example: %{"quiz_id" => 12, "question_duration_seconds" => 30}
    },
    struct?: false,
    derive?: false
  )
end
