defmodule LiveQuizWeb.UserLive.LoginTest do
  use LiveQuizWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import LiveQuiz.AccountsFixtures

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Entrar"
      assert html =~ "Cadastre-se"
      assert html =~ "Senha"
      assert html =~ "Esqueci minha senha"
    end
  end

  describe "user login" do
    test "redirects if user logs in with valid credentials", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form",
          user: %{email: user.email, password: valid_user_password(), remember_me: true}
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Bem-vindo de volta!"
      assert conn.resp_cookies["_live_quiz_web_user_remember_me"]
    end

    test "redirects to login page with a generic error if the password is wrong", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form = form(lv, "#login_form", user: %{email: user.email, password: "wrong password"})

      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "E-mail ou senha inválidos"
      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
    end

    test "does not disclose whether the email is registered", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form",
          user: %{email: "idonotexist@example.com", password: "123456789012"}
        )

      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "E-mail ou senha inválidos"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "login navigation" do
    test "redirects to registration page when the sign up link is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Cadastre-se")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/register")

      assert login_html =~ "Criar uma conta"
    end

    test "redirects to the forgot password page", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        lv
        |> element("main a", "Esqueci minha senha")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/reset-password")

      assert html =~ "Esqueci minha senha"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "shows login page with email filled in", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Confirme sua senha"
      refute html =~ "Cadastre-se"

      assert html =~
               ~s(<input type="email" name="user[email]" id="login_form_email" value="#{user.email}")
    end
  end
end
