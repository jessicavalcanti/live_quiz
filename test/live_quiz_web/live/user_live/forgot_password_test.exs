defmodule LiveQuizWeb.UserLive.ForgotPasswordTest do
  use LiveQuizWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import LiveQuiz.AccountsFixtures

  alias LiveQuiz.Accounts.UserToken
  alias LiveQuiz.Repo

  @info "Se esse e-mail estiver cadastrado, você receberá em instantes as instruções para redefinir sua senha."

  describe "Forgot password page" do
    test "renders the form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/reset-password")

      assert html =~ "Esqueci minha senha"
      assert html =~ "Entrar"
      assert html =~ "Cadastrar-se"
    end

    test "redirects if already logged in", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/reset-password")

      assert html =~ "Esqueci minha senha"
    end
  end

  describe "Reset link" do
    setup do
      %{user: user_fixture()}
    end

    test "sends a new reset password token", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password")

      {:ok, conn} =
        lv
        |> form("#forgot_password_form", user: %{"email" => user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) == @info
      assert Repo.get_by!(UserToken, user_id: user.id).context == "reset_password"
    end

    test "shows the same message and sends nothing for an unknown email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password")

      {:ok, conn} =
        lv
        |> form("#forgot_password_form", user: %{"email" => "unknown@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) == @info
      assert Repo.all(UserToken) == []
    end
  end
end
