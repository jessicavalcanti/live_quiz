defmodule LiveQuizWeb.UserLive.RegistrationTest do
  use LiveQuizWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import LiveQuiz.AccountsFixtures

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Criar uma conta"
      assert html =~ "Nome"
      assert html =~ "E-mail"
      assert html =~ "Senha"
      assert html =~ "Confirmação de senha"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/quizzes")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data without reloading the page", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"name" => "", "email" => "with spaces", "password" => "short"})

      assert result =~ "Criar uma conta"
      assert result =~ "precisa ter o sinal @ e não pode conter espaços"
      assert result =~ "não pode ficar em branco"
      assert result =~ "deve ter pelo menos 12 caracteres"
    end
  end

  describe "register user" do
    test "creates the account, sends the confirmation email and logs the user in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()
      form = form(lv, "#registration_form", user: valid_user_attributes(email: email))

      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/quizzes"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Conta criada com sucesso!"
      assert get_session(conn, :user_token)

      user = LiveQuiz.Accounts.get_user_by_email(email)
      assert user.name == valid_user_name()
      refute user.confirmed_at

      assert LiveQuiz.Repo.get_by!(LiveQuiz.Accounts.UserToken,
               user_id: user.id,
               context: "confirm"
             )
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      user = user_fixture(%{email: "ana@example.com"})

      result =
        lv
        |> form("#registration_form", user: valid_user_attributes(email: user.email))
        |> render_submit()

      assert result =~ "já está em uso"
      assert LiveQuiz.Repo.aggregate(LiveQuiz.Accounts.User, :count) == 1
    end

    test "renders an error when the name is missing", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> form("#registration_form", user: valid_user_attributes(name: ""))
        |> render_submit()

      assert result =~ "não pode ficar em branco"
      assert LiveQuiz.Repo.aggregate(LiveQuiz.Accounts.User, :count) == 0
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the log in link is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Entre")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert login_html =~ "Entrar"
    end
  end
end
