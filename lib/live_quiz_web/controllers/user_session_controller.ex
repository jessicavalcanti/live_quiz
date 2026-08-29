defmodule LiveQuizWeb.UserSessionController do
  use LiveQuizWeb, :controller

  alias LiveQuiz.Accounts
  alias LiveQuizWeb.UserAuth

  def create(conn, %{"_action" => "registered"} = params) do
    create(conn, params, "Conta criada com sucesso!")
  end

  def create(conn, %{"_action" => "password-updated"} = params) do
    create(conn, params, "Senha alterada com sucesso!")
  end

  def create(conn, params) do
    create(conn, params, "Bem-vindo de volta!")
  end

  defp create(conn, %{"user" => user_params}, info) do
    %{"email" => email, "password" => password} = user_params

    if user = Accounts.get_user_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, info)
      |> UserAuth.log_in_user(user, user_params)
    else
      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, "E-mail ou senha inválidos")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)
    {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

    # disconnect all existing LiveViews with old sessions
    UserAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:user_return_to, ~p"/users/settings")
    |> create(Map.put(params, "_action", "password-updated"))
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Sessão encerrada com sucesso.")
    |> UserAuth.log_out_user()
  end
end
