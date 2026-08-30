defmodule LiveQuizWeb.Api.V1.SessionController do
  @moduledoc """
  Exchanges credentials for JWTs and renews them.

  `create/2` and `refresh/2` are public; `delete/2` and `me/2` run behind
  `LiveQuizWeb.Api.AuthPipeline` and therefore always have a `current_scope`.
  """

  use LiveQuizWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias LiveQuiz.Accounts
  alias LiveQuiz.Accounts.Guardian
  alias LiveQuizWeb.Api.V1.Schemas.ErrorResponse
  alias LiveQuizWeb.Api.V1.Schemas.RefreshRequest
  alias LiveQuizWeb.Api.V1.Schemas.RefreshResponse
  alias LiveQuizWeb.Api.V1.Schemas.SessionRequest
  alias LiveQuizWeb.Api.V1.Schemas.SessionResponse
  alias LiveQuizWeb.Api.V1.Schemas.UserResponse
  alias LiveQuizWeb.Api.V1.Schemas.ValidationErrorResponse

  action_fallback LiveQuizWeb.Api.FallbackController

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
    with {:ok, user} <- Accounts.authenticate_by_credentials(params),
         {:ok, tokens} <- Guardian.build_tokens(user) do
      conn
      |> put_status(:created)
      |> render(:create, tokens: tokens, user: user)
    end
  end

  operation :refresh,
    summary: "Renova o token de acesso",
    description:
      "Troca um refresh token válido por um novo token de acesso. Não exige autenticação.",
    security: [],
    request_body: {"Refresh token", "application/json", RefreshRequest, required: true},
    responses: [
      ok: {"Novo token de acesso", "application/json", RefreshResponse},
      unauthorized: {"Refresh token inválido ou expirado", "application/json", ErrorResponse}
    ]

  def refresh(conn, %{"refresh_token" => refresh_token}) do
    with {:ok, tokens} <- Guardian.refresh_access_token(refresh_token) do
      render(conn, :refresh, tokens: tokens)
    end
  end

  def refresh(_conn, _params), do: {:error, :invalid_refresh_token}

  @doc """
  Ends the session on the client side.

  Without `Guardian.DB` there is nothing to invalidate on the server: the answer
  is `204` and the client is expected to discard both tokens.
  """
  operation :delete,
    summary: "Encerra a sessão",
    description:
      "Responde 204 e espera que o cliente descarte os dois tokens. Não há revogação no servidor.",
    security: [%{"bearerAuth" => []}],
    responses: [
      no_content: "Sessão encerrada",
      unauthorized: {"Não autenticado", "application/json", ErrorResponse}
    ]

  def delete(conn, _params), do: send_resp(conn, :no_content, "")

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
