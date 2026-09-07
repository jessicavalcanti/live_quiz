defmodule LiveQuizWeb.ParticipantAuth do
  @moduledoc """
  Keeps the credentials of someone taking part in rooms without an account.

  A participation is identified by an opaque token (AD-24) that the browser has
  to hold on to, because a guest has nothing else the server could recognize
  them by. It lives in the signed cookie `lq_participant`, `http_only` and
  `same_site: "Lax"`, valid for 30 days — long enough to survive the evening a
  room is played in, short enough not to linger forever.

  The cookie holds a **map of join code to token**, not a single token: someone
  who leaves one room to enter another must still be able to come back to the
  first one, which a single slot would have thrown away. Only the 20 most
  recently used entries are kept, so a browser that has been through many rooms
  never grows a cookie big enough to be refused. Recency is why the cookie
  stores an ordered list and only the readers see a map.

  The very same credentials feed `:known_tokens` on
  `LiveQuiz.Games.join_game_session/4`, which is how "one room per person"
  recognizes a guest (AD-28).

  ## Holding a credential and wanting to be taken back are different things

  Leaving a room used to erase the credential. For a guest that credential is
  the *only* thing the server can recognize them by: the domain keeps the
  participation and the nickname reserved for a return, and the browser was
  throwing away the one key to it — so the person could not go back to a room
  the context was still holding open for them, and the exclusivity check stopped
  seeing that room at all (R26).

  So an entry carries a state as well as a token. `active` is a room the browser
  would be taken straight back into; `left` is a room it still holds the key to
  and will not be walked into by accident. Both are known credentials;
  only `active` is an intent to enter. Entries written before this distinction
  existed are read as `active`, which is what they were.

  A LiveView cannot write cookies, and it cannot read them either — the socket
  only ever gets the Plug session. So `fetch_participant_tokens/2` runs in the
  browser pipeline, reads the cookie once and mirrors the credentials into the
  session, which is what `on_mount(:mount_participant_tokens, ...)` reads. It is
  the same detour `LiveQuizWeb.UserAuth` makes with the remember-me cookie.

  Nothing here ever raises. The value comes from the client, so a cookie that is
  absent, empty, truncated, signed with a retired secret or simply not a list of
  string pairs answers with `%{}` — losing a credential means being asked for a
  nickname again, while an exception would mean a screen that cannot be opened.
  """

  import Plug.Conn

  alias LiveQuiz.Games.JoinCode
  alias Phoenix.LiveView.Socket

  @cookie "lq_participant"
  @max_age 60 * 60 * 24 * 30
  @cookie_options [sign: true, max_age: @max_age, same_site: "Lax", http_only: true]
  @max_entries 20
  @session_key "participant_tokens"

  @doc "The name of the cookie the credentials live in."
  @spec cookie_name() :: String.t()
  def cookie_name, do: @cookie

  @doc "The session key the credentials are mirrored to, for LiveViews to read."
  @spec session_key() :: String.t()
  def session_key, do: @session_key

  @doc "How many rooms a browser remembers the credential of."
  @spec max_entries() :: pos_integer()
  def max_entries, do: @max_entries

  @doc "How long a credential survives in the browser, in seconds."
  @spec max_age() :: pos_integer()
  def max_age, do: @max_age

  @doc """
  Every credential the browser holds, whatever state it is in.

  This is what `:known_tokens` wants: exclusivity is a question about the rooms
  a guest is tied to, and a room they walked out of is still one of them until
  the domain says otherwise.

  Always answers with a map, whatever the client sent.
  """
  @spec read_tokens(Plug.Conn.t() | map()) :: %{String.t() => String.t()}
  def read_tokens(source), do: source |> entries(:all) |> Map.new(&{&1.code, &1.token})

  @doc """
  The credentials of the rooms the browser would be taken back into.

  What the join screen reads. A room the person left on purpose is not one of
  them: they still hold its key, and walking back in without being asked is not
  what "sair da sala" meant.
  """
  @spec resumable_tokens(Plug.Conn.t() | map()) :: %{String.t() => String.t()}
  def resumable_tokens(source) do
    source
    |> entries(:all)
    |> Enum.filter(&(&1.state == :active))
    |> Map.new(&{&1.code, &1.token})
  end

  defp entries(%Plug.Conn{} = conn, :all), do: read_entries(conn)

  defp entries(%{} = session, :all),
    do: session |> Map.get(@session_key) |> sanitize()

  @doc """
  Stores the credential of one room, keeping the 20 most recently used ones.

  Entering a room again replaces the token of that room instead of adding a
  second entry, and moves it to the front: the room a browser forgets is always
  the one it has not touched in the longest time.
  """
  @spec put_token(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def put_token(%Plug.Conn{} = conn, code, token) when is_binary(code) and is_binary(token) do
    normalized = JoinCode.normalize(code)

    entries =
      conn
      |> read_entries()
      |> Enum.reject(&(&1.code == normalized))
      |> Enum.take(@max_entries - 1)

    write(conn, [%{code: normalized, token: token, state: :active} | entries])
  end

  @doc """
  Marks the room as left, keeping the credential that can take the person back.

  Not the same as forgetting it. The domain keeps the participation and the
  nickname reserved, so the key has to survive; what changes is that the join
  screen stops walking back into that room on its own.
  """
  @spec mark_left(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def mark_left(%Plug.Conn{} = conn, code) when is_binary(code) do
    normalized = JoinCode.normalize(code)

    entries =
      conn
      |> read_entries()
      |> Enum.map(fn entry ->
        if entry.code == normalized, do: %{entry | state: :left}, else: entry
      end)

    write(conn, entries)
  end

  @doc "Forgets the credential of one room entirely, leaving every other one in place."
  @spec drop_token(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def drop_token(%Plug.Conn{} = conn, code) when is_binary(code) do
    normalized = JoinCode.normalize(code)

    entries = conn |> read_entries() |> Enum.reject(&(&1.code == normalized))

    write(conn, entries)
  end

  @doc """
  Puts the credentials of the connection into the session, for LiveViews to read.

  Runs in the browser pipeline so every screen — public or not — can tell
  whether the person is already in a room.
  """
  @spec fetch_participant_tokens(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def fetch_participant_tokens(%Plug.Conn{} = conn, _opts) do
    entries = read_entries(conn)

    conn
    |> assign(:participant_tokens, Map.new(entries, &{&1.code, &1.token}))
    |> put_session(@session_key, entries)
  end

  @doc """
  `on_mount` that assigns `:participant_tokens` from the session.

  Never halts: holding no credential is the ordinary state of someone opening
  the join screen for the first time.
  """
  @spec on_mount(atom(), map(), map(), Socket.t()) :: {:cont, Socket.t()}
  def on_mount(:mount_participant_tokens, _params, session, socket) do
    {:cont,
     socket
     |> Phoenix.Component.assign_new(:participant_tokens, fn -> read_tokens(session) end)
     |> Phoenix.Component.assign_new(:resumable_tokens, fn -> resumable_tokens(session) end)}
  end

  defp read_entries(%Plug.Conn{} = conn) do
    conn
    |> fetch_cookies(signed: [@cookie])
    |> Map.fetch!(:cookies)
    |> Map.get(@cookie)
    |> sanitize()
  end

  defp write(conn, entries) do
    conn = assign(conn, :participant_tokens, Map.new(entries, &{&1.code, &1.token}))

    if entries == [] do
      conn
      |> delete_resp_cookie(@cookie)
      |> delete_session(@session_key)
    else
      conn
      |> put_resp_cookie(@cookie, entries, @cookie_options)
      |> put_session(@session_key, entries)
    end
  end

  # Anything that is not a credential is dropped: a cookie that is only partly
  # readable is a cookie of unknown origin. A bare `{code, token}` pair is one
  # written before entries carried a state, and it meant a room the browser
  # would be taken back into — which is what `active` says.
  defp sanitize(entries) when is_list(entries) do
    entries
    |> Enum.flat_map(&entry/1)
    |> Enum.uniq_by(& &1.code)
    |> Enum.take(@max_entries)
  end

  defp sanitize(_entries), do: []

  defp entry(%{code: code, token: token, state: state})
       when is_binary(code) and is_binary(token) and state in [:active, :left],
       do: [%{code: code, token: token, state: state}]

  defp entry({code, token}) when is_binary(code) and is_binary(token),
    do: [%{code: code, token: token, state: :active}]

  defp entry(_not_a_credential), do: []
end
