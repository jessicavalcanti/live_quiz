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

  # A form posts two strings. A request written by hand posts whatever it likes,
  # and destructuring it turned "this is not a login" into a `MatchError` and a
  # 500 — an error page where a refusal belongs (R06).
  defp create(conn, %{"user" => user_params}, info) when is_map(user_params) do
    email = user_params["email"]
    password = user_params["password"]

    case Accounts.get_user_by_email_and_password(email, password) do
      %Accounts.User{} = user ->
        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      nil ->
        refuse_login(conn, email)
    end
  end

  defp create(conn, _params, _info), do: refuse_login(conn, nil)

  # In order to prevent user enumeration attacks, don't disclose whether the
  # email is registered. The address is echoed back only when it is a string:
  # anything else was never something somebody typed.
  defp refuse_login(conn, email) do
    conn
    |> put_flash(:error, "E-mail ou senha inválidos")
    |> put_flash(:email, if(is_binary(email), do: String.slice(email, 0, 160), else: ""))
    |> redirect(to: ~p"/users/log-in")
  end

  @doc """
  Changes the password of the authenticated user and logs them back in.

  Sudo is required, and an expired one sends the person to re-authenticate
  rather than raising: crossing the window between opening the page and
  submitting it is an ordinary thing for a tab to do, not an exception (R06).
  """
  def update_password(conn, %{"user" => user_params} = params) when is_map(user_params) do
    user = conn.assigns.current_scope.user

    with :ok <- UserAuth.ensure_sudo(user),
         {:ok, {_user, expired_tokens}} <- Accounts.update_user_password(user, user_params) do
      # disconnect all existing LiveViews with old sessions
      UserAuth.disconnect_sessions(expired_tokens)

      conn
      |> put_session(:user_return_to, ~p"/users/settings")
      |> create(Map.put(params, "_action", "password-updated"))
    else
      {:error, :sudo_required} ->
        UserAuth.require_reauthentication(conn, ~p"/users/settings")

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_flash(
          :error,
          "Não foi possível alterar a senha. Confira os campos e tente de novo."
        )
        |> redirect(to: ~p"/users/settings")
    end
  end

  def update_password(conn, _params) do
    conn
    |> put_flash(:error, "Não foi possível alterar a senha. Confira os campos e tente de novo.")
    |> redirect(to: ~p"/users/settings")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Sessão encerrada com sucesso.")
    |> UserAuth.log_out_user()
  end
end
