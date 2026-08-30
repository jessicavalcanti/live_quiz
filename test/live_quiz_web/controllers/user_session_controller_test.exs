defmodule LiveQuizWeb.UserSessionControllerTest do
  use LiveQuizWeb.ConnCase, async: true

  import LiveQuiz.AccountsFixtures

  alias LiveQuiz.Accounts
  alias LiveQuiz.Accounts.UserToken
  alias LiveQuiz.Repo

  setup do
    %{unconfirmed_user: unconfirmed_user_fixture(), user: user_fixture()}
  end

  describe "POST /users/log-in" do
    test "logs the user in", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ user.name
      assert response =~ ~p"/users/settings"
      assert response =~ ~p"/users/log-out"
    end

    test "logs an unconfirmed user in as well", %{conn: conn, unconfirmed_user: user} do
      refute user.confirmed_at

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
    end

    test "logs the user in with remember me", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_live_quiz_web_user_remember_me"]
      assert redirected_to(conn) == ~p"/"
    end

    test "logs the user in with return to", %{conn: conn, user: user} do
      conn =
        conn
        |> init_test_session(user_return_to: "/foo/bar")
        |> post(~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password()
          }
        })

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Bem-vindo de volta!"
    end

    test "greets a freshly registered user", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in?_action=registered", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Conta criada com sucesso!"
      assert redirected_to(conn) == ~p"/"
    end

    test "redirects to login page with a generic error on invalid credentials", %{
      conn: conn,
      user: user
    } do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "E-mail ou senha inválidos"
      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
    end

    test "does not disclose whether the email exists", %{conn: conn} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => "unknown@example.com", "password" => valid_user_password()}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "E-mail ou senha inválidos"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "DELETE /users/log-out" do
    test "logs the user out and removes the session token", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      token = get_session(conn, :user_token)
      assert Repo.get_by(UserToken, token: token)

      conn = delete(conn, ~p"/users/log-out")

      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      refute Repo.get_by(UserToken, token: token)
      refute Accounts.get_user_by_session_token(token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Sessão encerrada com sucesso."
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Sessão encerrada com sucesso."
    end
  end
end
