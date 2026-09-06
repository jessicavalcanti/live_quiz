defmodule LiveQuizWeb.Api.V1.GameSessionJSON do
  @moduledoc """
  Renders rooms inside the `data` envelope of the API.

  Three shapes, told apart by who is reading. `preview/1` is for somebody who
  has not entered the room: the title, the status and whether it still takes
  people, and nothing that would say who is inside or how many (AD-35).
  `show/1` is the whole room, for the host who owns it or for the client that
  just opened it, and `host_show/1` adds the lobby list to it.

  Every count in these payloads is handed over by the controller. This module
  reads no database and asks no presence, so the same room always serializes the
  same way whichever action rendered it.

  `join/1` is the only place in the whole API where the clear credential appears
  (AD-24). It is issued once and never given back, which is why it lives in the
  answer of a single render function instead of in the participation payload
  every other endpoint uses.
  """

  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.Participant
  alias LiveQuizWeb.Api.V1.ParticipantJSON

  @doc "Renders the whole room."
  def show(assigns), do: %{data: data(assigns)}

  @doc "Renders the whole room with the lobby list of the host."
  def host_show(%{participants: participants} = assigns) do
    %{
      data: Map.put(data(assigns), :participants, Enum.map(participants, &ParticipantJSON.data/1))
    }
  end

  @doc "Renders what a room tells somebody who has not entered it yet."
  def preview(%{session: %GameSession{} = session, preview: preview}) do
    %{
      data: %{
        code: session.join_code,
        quiz_title: preview.quiz_title,
        status: session.status,
        available: preview.available
      }
    }
  end

  @doc "Renders a brand new participation along with its clear credential."
  def join(%{participant: %Participant{} = participant, token: token}) do
    %{data: %{participant: ParticipantJSON.detail(participant), participant_token: token}}
  end

  defp data(%{
         session: %GameSession{} = session,
         reserved_slots: reserved_slots,
         connected_count: connected_count
       }) do
    %{
      code: session.join_code,
      status: session.status,
      quiz_title: session.quiz_title,
      quiz_id: session.quiz_id,
      reserved_slots: reserved_slots,
      max_participants: Games.max_participants(),
      connected_count: connected_count,
      started_at: session.started_at,
      finished_at: session.finished_at,
      expires_at: session.expires_at,
      inserted_at: session.inserted_at
    }
  end
end
