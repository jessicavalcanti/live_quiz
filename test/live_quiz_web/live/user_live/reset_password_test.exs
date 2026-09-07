defmodule LiveQuizWeb.UserLive.ResetPasswordTest do
  use LiveQuizWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import LiveQuiz.AccountsFixtures

  alias LiveQuiz.Accounts
  alias LiveQuiz.Repo

  setup do
    user = user_fixture()

    token =
      extract_user_token(fn url ->
        Accounts.deliver_user_reset_password_instructions(user, url)
      end)

    %{user: user, token: token}
  end

  describe "Reset password page" do
    test "renders the reset password form", %{conn: conn, token: token} do
      {:ok, _lv, html} = live(conn, ~p"/users/reset-password/#{token}")

      assert html =~ "Redefinir senha"
      assert html =~ "Nova senha"
    end

    test "does not render the form with an invalid token", %{conn: conn} do
      {:error, {:redirect, to}} = live(conn, ~p"/users/reset-password/invalid-token")

      assert to.to == ~p"/"
      assert to.flash["error"] =~ "inválido ou expirou"
    end
  end

  describe "Reset password" do
    test "resets the password and invalidates the active sessions", %{
      conn: conn,
      user: user,
      token: token
    } do
      session_token = Accounts.generate_user_session_token(user)

      {:ok, lv, _html} = live(conn, ~p"/users/reset-password/#{token}")

      {:ok, conn} =
        lv
        |> form("#reset_password_form",
          user: %{
            "password" => "new valid password",
            "password_confirmation" => "new valid password"
          }
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Senha redefinida com sucesso"
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
      refute Accounts.get_user_by_session_token(session_token)
      refute Accounts.get_user_by_reset_password_token(token)
    end

    test "logs in with the new password after resetting it", %{
      conn: conn,
      user: user,
      token: token
    } do
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password/#{token}")

      lv
      |> form("#reset_password_form",
        user: %{
          "password" => "new valid password",
          "password_confirmation" => "new valid password"
        }
      )
      |> render_submit()

      {:ok, login_lv, _html} = live(conn, ~p"/users/log-in")

      conn =
        login_lv
        |> form("#login_form", user: %{email: user.email, password: "new valid password"})
        |> submit_form(conn)

      assert redirected_to(conn) == ~p"/quizzes"
      assert get_session(conn, :user_token)
    end

    test "renders errors while typing (phx-change)", %{conn: conn, token: token} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password/#{token}")

      result =
        lv
        |> element("#reset_password_form")
        |> render_change(user: %{"password" => "short", "password_confirmation" => "another"})

      assert result =~ "deve ter pelo menos 12 caracteres"
      assert result =~ "não confere com a senha"
    end

    test "renders errors for invalid data", %{conn: conn, token: token} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password/#{token}")

      result =
        lv
        |> form("#reset_password_form",
          user: %{"password" => "short", "password_confirmation" => "another"}
        )
        |> render_submit()

      assert result =~ "deve ter pelo menos 12 caracteres"
      assert result =~ "não confere com a senha"
    end

    test "a second tab opened on the same link cannot reset again", %{
      conn: conn,
      user: user,
      token: token
    } do
      {:ok, first, _html} = live(conn, ~p"/users/reset-password/#{token}")
      {:ok, second, _html} = live(conn, ~p"/users/reset-password/#{token}")

      first
      |> form("#reset_password_form",
        user: %{
          "password" => "first valid password",
          "password_confirmation" => "first valid password"
        }
      )
      |> render_submit()

      refute Accounts.get_user_by_reset_password_token(token)

      {:ok, conn} =
        second
        |> form("#reset_password_form",
          user: %{
            "password" => "second valid password",
            "password_confirmation" => "second valid password"
          }
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "inválido ou expirou"
      assert Accounts.get_user_by_email_and_password(user.email, "first valid password")
      refute Accounts.get_user_by_email_and_password(user.email, "second valid password")
    end

    test "a token that expires after mount cannot reset", %{conn: conn, user: user, token: token} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password/#{token}")

      {1, nil} =
        Repo.update_all(
          from(t in LiveQuiz.Accounts.UserToken, where: t.context == "reset_password"),
          set: [inserted_at: ~N[2020-01-01 00:00:00]]
        )

      {:ok, conn} =
        lv
        |> form("#reset_password_form",
          user: %{
            "password" => "new valid password",
            "password_confirmation" => "new valid password"
          }
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "inválido ou expirou"
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end

    test "an invalid password keeps the link usable", %{conn: conn, user: user, token: token} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password/#{token}")

      lv
      |> form("#reset_password_form",
        user: %{"password" => "short", "password_confirmation" => "short"}
      )
      |> render_submit()

      assert Accounts.get_user_by_reset_password_token(token)

      lv
      |> form("#reset_password_form",
        user: %{
          "password" => "new valid password",
          "password_confirmation" => "new valid password"
        }
      )
      |> render_submit()

      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    # Deleting the session rows only blocks the *next* HTTP authentication. A
    # LiveView that already mounted keeps its scope until its socket is told to
    # disconnect, which is what this broadcast does — the same mechanism the
    # password change in UserSessionController uses.
    test "revokes the sockets of the sessions it expired", %{
      conn: conn,
      user: user,
      token: token
    } do
      session_token = Accounts.generate_user_session_token(user)
      topic = "users_sessions:#{Base.url_encode64(session_token)}"
      LiveQuizWeb.Endpoint.subscribe(topic)

      {:ok, lv, _html} = live(conn, ~p"/users/reset-password/#{token}")

      lv
      |> form("#reset_password_form",
        user: %{
          "password" => "new valid password",
          "password_confirmation" => "new valid password"
        }
      )
      |> render_submit()

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic}
    end

    test "does not revoke any socket when the token was already used", %{
      conn: conn,
      user: user,
      token: token
    } do
      {:ok, first, _html} = live(conn, ~p"/users/reset-password/#{token}")
      {:ok, second, _html} = live(conn, ~p"/users/reset-password/#{token}")

      first
      |> form("#reset_password_form",
        user: %{
          "password" => "first valid password",
          "password_confirmation" => "first valid password"
        }
      )
      |> render_submit()

      session_token = Accounts.generate_user_session_token(user)
      topic = "users_sessions:#{Base.url_encode64(session_token)}"
      LiveQuizWeb.Endpoint.subscribe(topic)

      second
      |> form("#reset_password_form",
        user: %{
          "password" => "second valid password",
          "password_confirmation" => "second valid password"
        }
      )
      |> render_submit()

      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic}
      assert Accounts.get_user_by_session_token(session_token)
    end
  end
end
