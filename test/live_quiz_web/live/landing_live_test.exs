defmodule LiveQuizWeb.LandingLiveTest do
  use LiveQuizWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "visitor" do
    test "sees the public pitch and both calls to action", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/")

      assert html =~ "Crie quizzes e jogue em tempo real"

      assert lv |> element(~s{a[href="/users/register"]}, "Criar conta") |> has_element?()
      assert lv |> element(~s{a[href="/users/log-in"]}, "Entrar") |> has_element?()
    end

    test "renders a single level one heading", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")

      assert html |> String.split("<h1") |> length() == 2
    end
  end

  describe "authenticated user" do
    setup :register_and_log_in_user

    test "is redirected to the quizzes page", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: path}}} = live(conn, ~p"/")
      assert path == ~p"/quizzes"
    end
  end
end
