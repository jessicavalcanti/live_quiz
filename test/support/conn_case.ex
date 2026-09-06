defmodule LiveQuizWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use LiveQuizWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint LiveQuizWeb.Endpoint

      use LiveQuizWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import LiveQuizWeb.ConnCase
    end
  end

  setup tags do
    LiveQuiz.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Setup helper that registers and logs in users.

      setup :register_and_log_in_user

  It stores an updated connection and a registered user in the
  test context.
  """
  def register_and_log_in_user(%{conn: conn} = context) do
    user = LiveQuiz.AccountsFixtures.user_fixture()
    scope = LiveQuiz.Accounts.Scope.for_user(user)

    opts =
      context
      |> Map.take([:token_authenticated_at])
      |> Enum.into([])

    %{conn: log_in_user(conn, user, opts), user: user, scope: scope}
  end

  @doc """
  Logs the given `user` into the `conn`.

  It returns an updated `conn`.
  """
  def log_in_user(conn, user, opts \\ []) do
    token = LiveQuiz.Accounts.generate_user_session_token(user)

    maybe_set_token_authenticated_at(token, opts[:token_authenticated_at])

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  @doc """
  Setup helper that registers a user and authenticates the `conn` with a JWT.

      setup :register_and_log_in_api_user

  """
  def register_and_log_in_api_user(%{conn: conn}) do
    user = LiveQuiz.AccountsFixtures.user_fixture()
    scope = LiveQuiz.Accounts.Scope.for_user(user)

    %{conn: log_in_api_user(conn, user), user: user, scope: scope}
  end

  @doc """
  Puts an `Authorization: Bearer <token>` header for the given user on the `conn`.

  Accepts the same options as `api_token/2`, so a test can authenticate with an
  already expired token or with a refresh token.
  """
  def log_in_api_user(conn, user, opts \\ []) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> api_token(user, opts))
  end

  @doc """
  Builds an API token for the given user.

  ## Options

    * `:token_type` - the `typ` claim, `"access"` by default;
    * `:ttl` - the token lifetime, 15 minutes by default. A negative value
      produces an already expired token.

  """
  def api_token(user, opts \\ []) do
    {:ok, token, _claims} =
      LiveQuiz.Accounts.Guardian.encode_and_sign(user, %{},
        token_type: Keyword.get(opts, :token_type, "access"),
        ttl: Keyword.get(opts, :ttl, {15, :minutes})
      )

    token
  end

  defp maybe_set_token_authenticated_at(_token, nil), do: nil

  defp maybe_set_token_authenticated_at(token, authenticated_at) do
    LiveQuiz.AccountsFixtures.override_token_authenticated_at(token, authenticated_at)
  end
end
