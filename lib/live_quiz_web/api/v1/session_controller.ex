defmodule LiveQuizWeb.Api.V1.SessionController do
  @moduledoc """
  Exchanges credentials for JWTs and renews them.

  `create/2` and `refresh/2` are public; `delete/2` and `me/2` run behind
  `LiveQuizWeb.Api.AuthPipeline` and therefore always have a `current_scope`.

  Being public is what makes them worth a budget. Checking a password costs a
  bcrypt hash — deliberately, that is the point of bcrypt — and an endpoint
  that hashes on demand for anybody is a lever. `create/2` is counted twice,
  by origin and by the account it names: the origin of a credential-stuffing
  run moves, and the account it targets does not (R05).
  """

  use LiveQuizWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias LiveQuiz.Accounts
  alias LiveQuiz.Accounts.Guardian
  alias LiveQuiz.RateLimit
  alias LiveQuizWeb.Api.V1.Schemas.ErrorResponse
  alias LiveQuizWeb.Api.V1.Schemas.RefreshRequest
  alias LiveQuizWeb.Api.V1.Schemas.RefreshResponse
  alias LiveQuizWeb.Api.V1.Schemas.SessionRequest
  alias LiveQuizWeb.Api.V1.Schemas.SessionResponse
  alias LiveQuizWeb.Api.V1.Schemas.UserResponse
  alias LiveQuizWeb.Api.V1.Schemas.ValidationErrorResponse

  action_fallback LiveQuizWeb.Api.FallbackController

  plug LiveQuizWeb.RateLimit, [bucket: :login_by_origin] when action == :create
  plug LiveQuizWeb.RateLimit, [bucket: :refresh_by_origin] when action == :refresh

  tags ["Sessão"]

  operation :create,
    summary: "Autentica o usuário e emite os tokens",
    description: "Troca e-mail e senha por um par de tokens. Não exige autenticação.",
    security: [],
    request_body: {"Credenciais do usuário", "application/json", SessionRequest, required: true},
    responses: [
      created: {"Tokens emitidos", "application/json", SessionResponse},
      unauthorized: {"E-mail ou senha inválidos", "application/json", ErrorResponse},
      unprocessable_entity:
        {"Credenciais incompletas", "application/json", ValidationErrorResponse}
    ]

  def create(conn, params) do
    with :ok <- spend_account_budget(params),
         {:ok, user} <- Accounts.authenticate_by_credentials(params),
         {:ok, tokens} <- Guardian.build_tokens(user) do
      conn
      |> put_status(:created)
      |> render(:create, tokens: tokens, user: user)
    end
  end

  # Spent before the hash, and keyed on the address as it was typed rather than
  # on the account it resolves to: looking the account up first would answer
  # "does this address exist" at whatever rate the caller likes, and the budget
  # has to hold for an address that does not exist just as it does for one that
  # does.
  defp spend_account_budget(%{"email" => email}) when is_binary(email) do
    case RateLimit.hit(:login_by_account, String.downcase(String.trim(email))) do
      :ok -> :ok
      {:error, retry_after} -> {:error, {:rate_limited, retry_after}}
    end
  end

  defp spend_account_budget(_params), do: :ok

  @doc """
  Renews the session, rotating the refresh token along with the access token.

  Each refresh token is spent once. Presenting a spent one is what a replay
  looks like from here, and the answer is to end the family: two holders spent
  one link, and there is no telling which of them logged in (R03).
  """
  operation :refresh,
    summary: "Renova os tokens da sessão",
    description: """
    Troca um refresh token válido por um novo par de tokens. Não exige autenticação.

    O refresh token enviado é **gasto**: guarde o novo, porque reapresentar o
    antigo encerra a sessão em todos os dispositivos que a compartilham.
    """,
    security: [],
    request_body: {"Refresh token", "application/json", RefreshRequest, required: true},
    responses: [
      ok: {"Novo par de tokens", "application/json", RefreshResponse},
      unauthorized: {"Refresh token inválido ou expirado", "application/json", ErrorResponse}
    ]

  def refresh(conn, %{"refresh_token" => refresh_token}) do
    with {:ok, tokens} <- Guardian.refresh_access_token(refresh_token) do
      render(conn, :refresh, tokens: tokens)
    end
  end

  def refresh(_conn, _params), do: {:error, :invalid_refresh_token}

  @doc """
  Ends the session, on the server as well as on the client.

  The refresh family goes with it, so the chain stops — the next link is exactly
  what a rotation would have issued, and revoking the row alone would leave it
  usable. The access token is not revoked and expires on its own within fifteen
  minutes; ending every session at once, immediately, is what a password reset
  does.

  Answers `204` whether or not a refresh token came with the request: a client
  discarding a credential should not learn from the status code whether the
  server had heard of it.
  """
  operation :delete,
    summary: "Encerra a sessão",
    description: """
    Encerra a sessão. Envie o `refresh_token` no corpo para revogá-la no
    servidor: sem ele, o token de renovação continua valendo até expirar.

    O token de acesso não é revogado e expira sozinho em quinze minutos.
    Encerrar **todas** as sessões de uma vez é o que a redefinição de senha faz.

    Responde `204` com ou sem corpo: um cliente descartando credencial não deve
    aprender pelo status se o servidor as conhecia.
    """,
    security: [%{"bearerAuth" => []}],
    responses: [
      no_content: "Sessão encerrada",
      unauthorized: {"Não autenticado", "application/json", ErrorResponse}
    ]

  def delete(conn, params) do
    Guardian.revoke_session(params["refresh_token"])

    send_resp(conn, :no_content, "")
  end

  operation :me,
    summary: "Dados do usuário autenticado",
    security: [%{"bearerAuth" => []}],
    responses: [
      ok: {"Usuário autenticado", "application/json", UserResponse},
      unauthorized: {"Não autenticado", "application/json", ErrorResponse}
    ]

  def me(conn, _params) do
    render(conn, :me, user: conn.assigns.current_scope.user)
  end
end
