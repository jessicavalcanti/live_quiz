defmodule LiveQuizWeb.QuizzesLiveTest do
  use LiveQuizWeb.ConnCase, async: true

  import LiveQuiz.AccountsFixtures
  import Phoenix.LiveViewTest

  describe "route protection" do
    test "redirects a visitor to the log in page", %{conn: conn} do
      assert {:error, {:redirect, %{to: path, flash: flash}}} = live(conn, ~p"/quizzes")

      assert path == ~p"/users/log-in"
      assert flash["error"] == "Você precisa entrar para acessar esta página."
    end

    test "stores the requested path so the user comes back after logging in", %{conn: conn} do
      conn = get(conn, ~p"/quizzes")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert get_session(conn, :user_return_to) == ~p"/quizzes"
    end
  end

  describe "authenticated user" do
    setup :register_and_log_in_user

    test "renders the page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/quizzes")

      assert html =~ "Meus quizzes"
    end
  end

  describe "authenticated header" do
    setup :register_and_log_in_user

    test "shows the user name and the account links", %{conn: conn, user: user} do
      {:ok, lv, html} = live(conn, ~p"/quizzes")

      assert html =~ user.name
      assert lv |> element(~s{a[href="/users/settings"]}, "Minha conta") |> has_element?()
      assert lv |> element(~s{a[href="/users/log-out"]}, "Sair") |> has_element?()
    end

    test "hides the confirmation notice for a confirmed user", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/quizzes")

      refute html =~ "Confirme seu e-mail"
    end
  end

  describe "unconfirmed e-mail notice" do
    setup %{conn: conn} do
      user = unconfirmed_user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "warns without blocking navigation", %{conn: conn, user: user} do
      {:ok, lv, html} = live(conn, ~p"/quizzes")

      assert html =~ "Confirme seu e-mail"
      assert html =~ user.email

      # the page still renders its own content and the menu stays usable
      assert html =~ "Meus quizzes"
      assert lv |> element(~s{a[href="/users/settings"]}, "Minha conta") |> has_element?()
    end
  end
end
