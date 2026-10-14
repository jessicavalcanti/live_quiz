defmodule LiveQuizWeb.LayoutsTest do
  use LiveQuizWeb.ConnCase, async: true

  test "uses the lightning brand and favicon on application screens", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(id="app-brand")
    assert html =~ "⚡"
    assert html =~ ~s(rel="icon" type="image/svg+xml" href="/images/favicon.svg")
  end

  test "shows the application name only once when a page has no explicit title", %{conn: conn} do
    html = conn |> get(~p"/users/log-in") |> html_response(200)

    assert html =~ ~r/<title[^>]*>Início · LiveQuiz<\/title>/
    refute html =~ "LiveQuiz · LiveQuiz"
  end

  test "uses the lightning brand and favicon on the not-found screen" do
    html = Phoenix.Template.render_to_string(LiveQuizWeb.ErrorHTML, "404", "html", %{})

    assert html =~ "⚡"
    assert html =~ ~s(rel="icon" type="image/svg+xml" href="/images/favicon.svg")
  end
end
