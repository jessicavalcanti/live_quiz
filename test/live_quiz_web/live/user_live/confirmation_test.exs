defmodule LiveQuizWeb.UserLive.ConfirmationTest do
  use LiveQuizWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import LiveQuiz.AccountsFixtures

  alias LiveQuiz.Accounts

  setup do
    user = unconfirmed_user_fixture()

    token =
      extract_user_token(fn url ->
        Accounts.deliver_user_confirmation_instructions(user, url)
      end)

    %{user: user, token: token}
  end

  describe "Confirm account" do
    test "renders confirmation page", %{conn: conn, token: token} do
      {:ok, _lv, html} = live(conn, ~p"/users/confirm/#{token}")

      assert html =~ "Confirmar conta"
      assert html =~ "Confirmar minha conta"
    end

    test "confirms the given token once", %{conn: conn, user: user, token: token} do
      {:ok, lv, _html} = live(conn, ~p"/users/confirm/#{token}")

      {:ok, conn} =
        lv
        |> form("#confirmation_form")
        |> render_submit()
        |> follow_redirect(conn, ~p"/")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Conta confirmada com sucesso."
      assert Accounts.get_user!(user.id).confirmed_at

      # The same link cannot be used twice.
      {:ok, lv, _html} = live(build_conn(), ~p"/users/confirm/#{token}")

      {:ok, conn} =
        lv
        |> form("#confirmation_form")
        |> render_submit()
        |> follow_redirect(build_conn(), ~p"/")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "inválido ou expirou"
    end

    test "does not confirm with an invalid token", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/confirm/invalid-token")

      {:ok, conn} =
        lv
        |> form("#confirmation_form")
        |> render_submit()
        |> follow_redirect(conn, ~p"/")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "inválido ou expirou"
      refute Accounts.get_user!(user.id).confirmed_at
    end

    test "does not complain when the logged in user is already confirmed", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, lv, _html} = live(conn, ~p"/users/confirm/already-used-token")

      {:ok, conn} =
        lv
        |> form("#confirmation_form")
        |> render_submit()
        |> follow_redirect(conn, ~p"/")

      refute Phoenix.Flash.get(conn.assigns.flash, :error)
    end
  end

  describe "unconfirmed account" do
    test "can browse the authenticated area normally", %{conn: conn, user: user} do
      refute user.confirmed_at

      conn = log_in_user(conn, user)

      assert html_response(get(conn, ~p"/quizzes"), 200) =~ user.name

      {:ok, _lv, html} = live(conn, ~p"/users/settings")
      assert html =~ "Configurações da conta"
    end
  end
end
