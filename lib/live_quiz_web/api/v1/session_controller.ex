defmodule LiveQuizWeb.Api.V1.SessionController do
  @moduledoc """
  Exchanges credentials for JWTs and renews them.

  `create/2` and `refresh/2` are public; `delete/2` and `me/2` run behind
  `LiveQuizWeb.Api.AuthPipeline` and therefore always have a `current_scope`.
  """

  use LiveQuizWeb, :controller

  alias LiveQuiz.Accounts
  alias LiveQuiz.Accounts.Guardian

  action_fallback LiveQuizWeb.Api.FallbackController

  def create(conn, params) do
    with {:ok, user} <- Accounts.authenticate_by_credentials(params),
         {:ok, tokens} <- Guardian.build_tokens(user) do
      conn
      |> put_status(:created)
      |> render(:create, tokens: tokens, user: user)
    end
  end

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
  def delete(conn, _params), do: send_resp(conn, :no_content, "")

  def me(conn, _params) do
    render(conn, :me, user: conn.assigns.current_scope.user)
  end
end
