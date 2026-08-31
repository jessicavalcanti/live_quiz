defmodule LiveQuizWeb.Api.V1.ParticipantController do
  @moduledoc """
  What somebody taking part in a room can do over JSON once they are in it.

  The credential the pipeline resolved says *who* is asking; the code in the
  address says *which room* is being asked about, and the two have to agree. A
  credential of another room is not an identity for this one, so it answers
  `404` — the same answer as a code that never existed, because from outside the
  two are indistinguishable (AD-10).

  Leaving and coming back both act on the participation the credential names, so
  neither takes a body. Leaving is idempotent by the context's own definition,
  and coming back is refused with `410` once the room is over: the credential
  died with its room, which is a different piece of news from a credential that
  never bought anything.

  The lobby list is the one action that takes either identity — the credential
  of somebody inside the room, or the JWT of the host. Both are tried, so a host
  who is also taking part is answered by whichever of the two is allowed, and
  anybody else identified is `403` rather than an empty list that would pretend
  the room is deserted (AD-35).

  The clear credential is never in any of these answers. It is issued once, by
  the join endpoint, and this controller only ever reads what it identifies.
  """

  use LiveQuizWeb, :controller

  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.JoinCode
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Games.Presence

  action_fallback LiveQuizWeb.Api.FallbackController

  @doc """
  The lobby list of a room, for whoever is inside it or hosts it.
  """
  def index(conn, %{"code" => code}) do
    with {:ok, %GameSession{} = session} <- Games.get_game_session_by_code(code),
         {:ok, participants} <- list_participants(session, conn) do
      render(conn, :index, participants: participants)
    end
  end

  @doc """
  The participation the presented credential names.
  """
  def show(conn, %{"code" => code}) do
    with {:ok, %Participant{} = participant, _token} <- participation(conn, code) do
      render(conn, :show, participant: with_presence(participant))
    end
  end

  @doc """
  Comes back to a participation that is still reserved, after leaving or after
  simply dropping off.
  """
  def rejoin(conn, %{"code" => code}) do
    with {:ok, %Participant{}, token} <- participation(conn, code),
         {:ok, %Participant{} = participant} <-
           Games.rejoin_game_session(token, known_tokens: [token]) do
      render(conn, :show, participant: with_presence(participant))
    end
  end

  @doc """
  Leaves the room on purpose, freeing the person to enter another one.
  """
  def leave(conn, %{"code" => code}) do
    with {:ok, %Participant{} = participant, _token} <- participation(conn, code),
         {:ok, %Participant{}} <- Games.leave_game_session(participant) do
      send_resp(conn, :no_content, "")
    end
  end

  # The room is read from the credential rather than from the address, so it is
  # found whether it is live or already over — which is what lets coming back to
  # a cancelled room be answered as an ending instead of as an unknown token.
  # The address still has to name that same room.
  defp participation(conn, code) do
    with {:ok, token} <- credential(conn),
         {:ok, %GameSession{} = session} <- Games.get_session_by_participant_token(token),
         true <- session.join_code == JoinCode.normalize(code) do
      {:ok, conn.assigns.current_participant, token}
    else
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp credential(conn) do
    case conn.assigns[:participant_token] do
      token when is_binary(token) -> {:ok, token}
      nil -> {:error, :unauthenticated}
    end
  end

  # A request may carry an account and a participation at once, and the two are
  # allowed to read the lobby for different reasons. Both are offered to the
  # context, which is the only place that decides.
  defp list_participants(%GameSession{} = session, conn) do
    [conn.assigns[:current_scope], conn.assigns[:current_participant]]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce_while({:error, :unauthorized}, fn viewer, refusal ->
      case Games.list_participants_with_presence(session, viewer) do
        {:ok, participants} -> {:halt, {:ok, participants}}
        {:error, :unauthorized} -> {:cont, refusal}
      end
    end)
  end

  # A REST client is never itself connected to a room — there is no socket to
  # hold a presence — but the participation it reads may well be open in a
  # browser, so the field is filled from the same presence the lobby list uses
  # instead of always answering "false".
  defp with_presence(%Participant{} = participant) do
    connected = Presence.connected_participant_ids(participant.game_session_id)

    %{participant | connected: MapSet.member?(connected, participant.id)}
  end
end
