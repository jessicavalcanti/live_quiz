defmodule LiveQuizWeb.Api.V1.GameSessionController do
  @moduledoc """
  Rooms over JSON: opening one, reading it, entering it and ending it.

  Not a single rule lives here. The controller reads the identity the pipeline
  put on the connection, calls `LiveQuiz.Games` with it and renders the answer;
  every refusal comes back from the context as an atom and becomes a status in
  `LiveQuizWeb.Api.FallbackController` (AD-01), so the API and the web refuse
  the very same things for the very same reasons.

  Rooms are addressed by their join code and never by their id: the code is what
  a client actually holds, and it keeps a sequential identifier out of an
  address that people without an account are meant to use. A room hosted by
  somebody else answers `404` rather than `403`, so the API never confirms that
  it exists (AD-10) — which is also the answer for a request that names no quiz
  at all.

  What the public read tells is deliberately thin (AD-35): the title, the status
  and whether the room still takes people. Never who is inside, never how many —
  not even as a count, since a room one seat from full and an empty one are
  equally "available".

  Starting a room does not trust the client with the number of people connected.
  `LiveQuiz.Games.Presence` is asked here and its answer is handed to the
  context (AD-23), so a `connected_count` sent in the body is read by nobody.
  """

  use LiveQuizWeb, :controller

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.Presence
  alias LiveQuizWeb.Api.ParticipantAuth

  action_fallback LiveQuizWeb.Api.FallbackController

  # Entering a room is open to whoever has no account at all, so nothing is
  # required here. The plug still resolves what is presented: a JWT ties the
  # participation to the account, and the credentials of other rooms are what
  # let "one room per person" recognize a guest (AD-28).
  plug ParticipantAuth, [require: false] when action in [:join]

  @doc """
  Opens a room for a quiz of the authenticated user.
  """
  def create(conn, %{"quiz_id" => quiz_id}) do
    with {:ok, %GameSession{} = session} <- open_room(conn.assigns.current_scope, quiz_id) do
      conn
      |> put_status(:created)
      |> render(:show, room(session))
    end
  end

  def create(_conn, _params), do: {:error, :not_found}

  @doc """
  The public read of a room by its code, restricted to what somebody who has not
  entered it yet may know.
  """
  def show(conn, %{"code" => code}) do
    # Two reads rather than one: the availability is a rule and belongs to
    # `preview_by_code/1`, while the code and the status are plain fields of the
    # room. Restating the rule here would be the first place the API and the web
    # could disagree about whether a room still takes people.
    with {:ok, %GameSession{} = session} <- Games.get_game_session_by_code(code),
         {:ok, preview} <- Games.preview_by_code(code) do
      render(conn, :preview, session: session, preview: preview)
    end
  end

  @doc """
  The read of the host: the whole room, with the lobby list.
  """
  def host_show(conn, %{"code" => code}) do
    scope = conn.assigns.current_scope

    with {:ok, %GameSession{} = session} <- hosted_room(scope, code),
         {:ok, participants} <- Games.list_participants_with_presence(session, scope) do
      render(conn, :host_show, Map.put(room(session), :participants, participants))
    end
  end

  @doc """
  Puts somebody into a room, with an account or without one.

  The clear credential is in the answer of this action and of no other: it is
  never reissued, so losing it is losing that participation (AD-24).
  """
  def join(conn, %{"code" => code} = params) do
    scope = conn.assigns[:current_scope]
    known = ParticipantAuth.presented_tokens(conn)

    with {:ok, participant, token} <-
           Games.join_game_session(scope, code, join_params(params), known_tokens: known) do
      conn
      |> put_status(:created)
      |> render(:join, participant: participant, token: token)
    end
  end

  @doc """
  Puts the room live. Only the host, only from the lobby, and only with somebody
  connected — counted by the server.
  """
  def start(conn, %{"code" => code}) do
    scope = conn.assigns.current_scope

    with {:ok, %GameSession{} = session} <- hosted_room(scope, code),
         {:ok, %GameSession{} = session} <-
           Games.start_game_session(scope, session, Presence.connected_count(session.id)) do
      render(conn, :show, room(session))
    end
  end

  @doc """
  Ends the room by the host's own decision, in the lobby or after it started.
  """
  def cancel(conn, %{"code" => code}) do
    scope = conn.assigns.current_scope

    with {:ok, %GameSession{} = session} <- hosted_room(scope, code),
         {:ok, %GameSession{} = session} <- Games.cancel_game_session(scope, session) do
      render(conn, :show, room(session))
    end
  end

  # Everything a room answers with beyond its own columns. The seats come from
  # the database and the connected people from the presence, and both are read
  # here so the view stays a serializer and touches neither.
  defp room(%GameSession{} = session) do
    %{
      session: session,
      reserved_slots: Games.reserved_slots(session),
      connected_count: Presence.connected_count(session.id)
    }
  end

  # The context reads with a bang function, exactly like the lobby of the host
  # does. The rescue lives here so the actions stay free of `try/rescue` and a
  # room somebody else hosts leaves as the 404 envelope of the API.
  defp hosted_room(%Scope{} = scope, code) do
    {:ok, Games.get_hosted_session_by_code!(scope, code)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  # A quiz of somebody else raises inside the transaction; an id that is not one
  # never reaches the database. Both mean the same thing to a client: there is
  # no such quiz.
  defp open_room(%Scope{} = scope, quiz_id) do
    Games.create_game_session(scope, quiz_id)
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    Ecto.Query.CastError -> {:error, :not_found}
    ArgumentError -> {:error, :not_found}
  end

  # Only the nickname comes from the body. Anything else is ignored, and a body
  # without it is an empty participation — which the changeset answers with 422
  # instead of a 500.
  defp join_params(params), do: Map.take(params, ["nickname"])
end
