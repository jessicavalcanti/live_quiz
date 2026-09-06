defmodule LiveQuizWeb.GameResultLive.IndexTest do
  use LiveQuizWeb.ConnCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import LiveQuiz.QuizzesFixtures
  import Phoenix.LiveViewTest

  alias LiveQuiz.Accounts.Scope

  setup :register_and_log_in_user

  test "lists only the user's finished results", %{conn: conn, user: user} do
    own = result_fixture(user, "Meu quiz")
    other = result_fixture(user_fixture(), "Outro quiz")

    {:ok, _lv, html} = live(conn, ~p"/game-results")

    assert html =~ own.quiz_title
    refute html =~ other.quiz_title
  end

  test "shows the empty state", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/game-results")

    assert html =~ "Você ainda não tem partidas finalizadas."
  end

  test "paginates and combines quiz and date filters", %{conn: conn, user: user} do
    quiz = quiz_fixture(Scope.for_user(user), %{title: "Filtrado"})
    for _ <- 1..11, do: result_fixture(user, "Filtrado", quiz: quiz)

    {:ok, lv, html} = live(conn, ~p"/game-results")
    assert html =~ "Página 1 de 2"
    refute html =~ "Página 2 de 2"

    html = lv |> element("a", "Próxima") |> render_click()
    assert_patch(lv, ~p"/game-results?page=2")
    assert html =~ "Página 2 de 2"

    html =
      lv
      |> form("#game-results-filters", %{
        "filters" => %{
          "quiz_id" => to_string(quiz.id),
          "from" => "2026-09-01",
          "to" => "2026-09-30"
        }
      })
      |> render_submit()

    assert_patch(lv, ~p"/game-results?from=2026-09-01&page=1&quiz_id=#{quiz.id}&to=2026-09-30")
    assert html =~ "Filtrado"
  end

  defp result_fixture(user, title, attrs \\ []) do
    quiz =
      Keyword.get_lazy(attrs, :quiz, fn -> quiz_fixture(Scope.for_user(user), %{title: title}) end)

    session = game_session_fixture(%{host: user, quiz: quiz, status: :finished})
    participant = participant_fixture(session, %{user: user, released_at: now()})
    game_result_fixture(session, participant, %{quiz_title: title})
  end
end
