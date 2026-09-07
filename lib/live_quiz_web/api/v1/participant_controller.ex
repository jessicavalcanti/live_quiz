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
  use OpenApiSpex.ControllerSpecs

  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.JoinCode
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Games.Presence
  alias LiveQuizWeb.Api.ParticipantAuth
  alias LiveQuizWeb.Api.V1.Schemas.ErrorResponse
  alias LiveQuizWeb.Api.V1.Schemas.ParticipantListResponse
  alias LiveQuizWeb.Api.V1.Schemas.ParticipantResponse
  alias LiveQuizWeb.Api.Viewer

  action_fallback LiveQuizWeb.Api.FallbackController

  tags ["Salas"]

  @code_parameter [
    in: :path,
    description: "Código de acesso da sala, com 6 caracteres",
    type: :string,
    required: true,
    example: "K7P4Q2"
  ]

  @doc """
  The lobby list of a room, for whoever is inside it or hosts it.
  """
  operation :index,
    summary: "Lista o lobby da sala",
    description: """
    A única operação que aceita as duas identidades: a credencial de quem está na
    sala ou o `Bearer` do host. Quem é identificado mas não é nenhum dos dois
    recebe `403`, nunca uma lista vazia que fingiria a sala deserta (AD-35).
    """,
    security: [%{"participantAuth" => []}, %{"bearerAuth" => []}],
    parameters: [code: @code_parameter],
    responses: [
      ok: {"Participações da sala", "application/json", ParticipantListResponse},
      unauthorized: {"Sem credencial nem token de conta", "application/json", ErrorResponse},
      forbidden:
        {"Identificado, mas sem participação nem host nesta sala", "application/json",
         ErrorResponse},
      not_found:
        {"Sala inexistente, encerrada ou código inválido", "application/json", ErrorResponse}
    ]

  def index(conn, %{"code" => code}) do
    with {:ok, %GameSession{} = session} <- Games.get_game_session_by_code(code),
         {:ok, participants} <-
           Viewer.read(conn, &Games.list_participants_with_presence(session, &1)) do
      render(conn, :index, participants: participants)
    end
  end

  @doc """
  The participation the presented credential names.
  """
  operation :show,
    summary: "Detalha a própria participação",
    security: [%{"participantAuth" => []}],
    description: """
    Exige a credencial de participação: o `Bearer` do host não identifica
    participação nenhuma e recebe `401`. A credencial precisa ser da sala que o
    código endereça; a de outra sala responde `404`.

    A resposta **não** traz o `participant_token`: ele é devolvido uma única vez,
    na entrada.
    """,
    parameters: [code: @code_parameter],
    responses: [
      ok: {"Participação encontrada", "application/json", ParticipantResponse},
      unauthorized: {"Credencial ausente ou inválida", "application/json", ErrorResponse},
      not_found:
        {"Credencial de outra sala ou sala inexistente", "application/json", ErrorResponse}
    ]

  def show(conn, %{"code" => code}) do
    with {:ok, %Participant{} = participant, _token} <- participation(conn, code) do
      render(conn, :show, participant: with_presence(participant))
    end
  end

  @doc """
  Comes back to a participation that is still reserved, after leaving or after
  simply dropping off.
  """
  operation :rejoin,
    summary: "Retoma a participação",
    security: [%{"participantAuth" => []}],
    description: """
    Funciona com a sala em `waiting` ou `in_progress` e preserva o apelido e o
    assento. Sala já encerrada responde `410`: a credencial morreu com a sala,
    notícia diferente de uma credencial que nunca valeu nada.
    """,
    parameters: [code: @code_parameter],
    responses: [
      ok: {"Participação retomada", "application/json", ParticipantResponse},
      unauthorized: {"Credencial ausente ou inválida", "application/json", ErrorResponse},
      not_found:
        {"Credencial de outra sala ou sala inexistente", "application/json", ErrorResponse},
      conflict: {"Você já está participando de outra sala", "application/json", ErrorResponse},
      gone: {"Esta sala foi encerrada", "application/json", ErrorResponse}
    ]

  def rejoin(conn, %{"code" => code}) do
    with {:ok, %Participant{}, token} <- participation(conn, code),
         # Every credential the client presented, not just the one this room
         # was resolved from. Exclusivity is a question about the *other*
         # rooms a guest is holding, and answering it from a single token is
         # answering it with the one identity that cannot conflict with
         # itself (R27).
         {:ok, %Participant{} = participant} <-
           Games.rejoin_game_session(token,
             known_tokens: ParticipantAuth.presented_tokens(conn)
           ) do
      render(conn, :show, participant: with_presence(participant))
    end
  end

  @doc """
  Leaves the room on purpose, freeing the person to enter another one.
  """
  operation :leave,
    summary: "Sai da sala",
    security: [%{"participantAuth" => []}],
    description: """
    Idempotente: sair de novo continua respondendo `204`. O assento **não** é
    devolvido à sala (AD-27), mas a pessoa fica livre para entrar em outra.
    """,
    parameters: [code: @code_parameter],
    responses: [
      no_content: "Saída registrada",
      unauthorized: {"Credencial ausente ou inválida", "application/json", ErrorResponse},
      not_found:
        {"Credencial de outra sala ou sala inexistente", "application/json", ErrorResponse}
    ]

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
  # The credential of *this* room, chosen among the ones presented. The plug
  # resolves the first one that names any participation, which is the right
  # answer for an endpoint about "you" and the wrong one here: a client holding
  # two credentials would have the room picked by the order of its headers
  # (R27).
  defp participation(conn, code) do
    with {:ok, _any} <- credential(conn) do
      credential_for_room(conn, JoinCode.normalize(code))
    end
  end

  defp credential_for_room(conn, code) do
    conn
    |> ParticipantAuth.presented_tokens()
    |> Enum.find_value(fn token ->
      with {:ok, %GameSession{join_code: ^code}} <- Games.get_session_by_participant_token(token),
           {:ok, participant} <- Games.get_participation_by_token(token) do
        {:ok, participant, token}
      else
        _another_room_or_invalid -> nil
      end
    end)
    |> case do
      nil -> {:error, :not_found}
      found -> found
    end
  end

  defp credential(conn) do
    case conn.assigns[:participant_token] do
      token when is_binary(token) -> {:ok, token}
      nil -> {:error, :unauthenticated}
    end
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
