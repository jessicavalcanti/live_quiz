defmodule LiveQuizWeb.UserLive.ResetPasswordTest do
  use LiveQuizWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import LiveQuiz.AccountsFixtures

  alias LiveQuiz.Accounts

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
  end
end
