defmodule LiveQuizWeb.Api.ParticipantAuth do
  @moduledoc """
  Resolves who is talking to a room over the JSON API.

  Two credentials share the `Authorization` header and they are never
  interchangeable. A participation presents `Authorization: Participant <token>`,
  the opaque credential of AD-24, and it is the only identity somebody without
  an account ever has. An account presents `Authorization: Bearer <jwt>`, which
  the rest of the API already speaks. A `Bearer` is not read as a participation
  and a `Participant` is not read as a token, so neither scheme can be smuggled
  in place of the other.

  Whatever is presented, the plug decides nothing about the room: it puts the
  participation in `conn.assigns.current_participant`, the clear credential in
  `conn.assigns.participant_token` and the account scope in
  `conn.assigns.current_scope`, and the controllers go on asking
  `LiveQuiz.Games`. The JWT is resolved first, through the very same pipeline
  the authenticated endpoints use, so an expired or forged token is refused here
  exactly as it is there; the credential is resolved after it, so a client
  holding both — an account that is also taking part — sends both headers and is
  recognized as both.

  By default a request carrying neither identity, or a participant token that
  buys nothing, is `401` and stops here. A credential is **not** refused for
  belonging to a room that is already over: telling that apart from a credential
  nobody ever issued is what lets `rejoin` answer `410` instead of hiding the
  ending behind a `401`.

  `require: false` keeps the very same resolution and never refuses anything. It
  is what entering a room uses: joining is open to people with no identity at
  all, while a client that does hold credentials still gets its account
  recognized and its tokens read as `:known_tokens`.
  """

  @behaviour Plug

  import Plug.Conn

  alias LiveQuiz.Games
  alias LiveQuizWeb.Api.AuthPipeline
  alias LiveQuizWeb.Api.ErrorJSON

  @scheme "participant"
  @bearer_scheme "bearer"

  @impl Plug
  def init(opts), do: Keyword.get(opts, :require, true)

  @impl Plug
  def call(conn, required?) do
    conn
    |> authenticate_user()
    |> authenticate_participant(required?)
    |> ensure_identified(required?)
  end

  @doc """
  The clear participant tokens presented in the `Authorization` headers.

  Public because entering a room is not behind this plug and still has to read
  them: they are the `:known_tokens` of `LiveQuiz.Games.join_game_session/4`,
  the only way the server can notice that a client without an account is already
  taking part somewhere else (AD-28).
  """
  @spec presented_tokens(Plug.Conn.t()) :: [String.t()]
  def presented_tokens(%Plug.Conn{} = conn) do
    conn
    |> credentials()
    |> Enum.flat_map(fn {scheme, token} -> if scheme == @scheme, do: [token], else: [] end)
  end

  # The JWT goes through the pipeline of the authenticated endpoints, so there
  # is a single place where a token is verified and a scope is assigned. It only
  # runs when a `Bearer` header is actually there: running it without one would
  # refuse every guest before the credential had a chance to be read.
  defp authenticate_user(conn) do
    if bearer?(conn) do
      AuthPipeline.call(conn, AuthPipeline.init([]))
    else
      conn
    end
  end

  defp authenticate_participant(%Plug.Conn{halted: true} = conn, _required?), do: conn

  defp authenticate_participant(conn, required?) do
    case presented_tokens(conn) do
      [] -> conn
      tokens -> resolve(conn, tokens, required?)
    end
  end

  # A credential that resolves to nothing is refused rather than ignored: it is
  # the client claiming an identity the server cannot find. Where nothing is
  # required it is only a hint about other rooms, so it is dropped in silence.
  defp resolve(conn, tokens, required?) do
    case Enum.find_value(tokens, &participation/1) do
      {participant, token} ->
        conn
        |> assign(:current_participant, participant)
        |> assign(:participant_token, token)

      nil ->
        if required?, do: unauthorized(conn), else: conn
    end
  end

  defp participation(token) do
    case Games.get_participation_by_token(token) do
      {:ok, participant} -> {participant, token}
      {:error, :not_found} -> nil
    end
  end

  defp ensure_identified(%Plug.Conn{halted: true} = conn, _required?), do: conn
  defp ensure_identified(conn, false), do: conn

  defp ensure_identified(conn, true) do
    if conn.assigns[:current_participant] || conn.assigns[:current_scope] do
      conn
    else
      unauthorized(conn)
    end
  end

  defp bearer?(conn) do
    conn |> credentials() |> Enum.any?(fn {scheme, _token} -> scheme == @bearer_scheme end)
  end

  # Several `Authorization` headers are allowed on purpose: it is how one
  # request carries an account and a participation at the same time. Anything
  # that is not `<scheme> <value>` is not a credential and is dropped.
  defp credentials(conn) do
    conn
    |> get_req_header("authorization")
    |> Enum.flat_map(&credential/1)
  end

  defp credential(header) do
    case header |> String.trim() |> String.split(~r/\s+/, parts: 2) do
      [scheme, value] -> [{String.downcase(scheme), value}]
      _not_a_credential -> []
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(ErrorJSON.render("401.json", %{}))
    |> halt()
  end
end
