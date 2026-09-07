defmodule LiveQuizWeb.GameHistoryLiveTest do
  use LiveQuizWeb.ConnCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "host sees finished history, ranking and participant details", %{conn: conn, user: user} do
    session = game_session_fixture(%{host: user, status: :finished})
    participant = participant_fixture(session, %{user: user_fixture(), nickname: "João"})

    result =
      game_result_fixture(session, participant, %{
        question_results: %{"1" => %{"question" => "2 + 2?", "answer" => "4", "correct" => true}}
      })

    {:ok, _lv, html} = live(conn, ~p"/game-history")
    assert html =~ session.quiz_title
    assert html =~ "João"

    {:ok, _lv, html} = live(conn, ~p"/game-history/#{session.id}")
    assert html =~ "Ranking completo"
    assert html =~ "João"

    {:ok, _lv, html} = live(conn, ~p"/game-history/#{session.id}/participants/#{result.id}")
    assert html =~ "2 + 2?"
    assert html =~ "Correta"
  end

  test "host history does not expose another host or cancelled matches", %{conn: conn, user: user} do
    other = user_fixture()
    game_session_fixture(%{host: other, status: :finished})
    game_session_fixture(%{host: user, status: :cancelled})

    {:ok, _lv, html} = live(conn, ~p"/game-history")
    assert html =~ "Nenhuma partida finalizada encontrada."
  end

  test "host detail returns 404 for another host", %{conn: conn} do
    session = game_session_fixture(%{host: user_fixture(), status: :finished})
    assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/game-history/#{session.id}") end
  end

  test "requires authentication", %{conn: conn, user: user} do
    session = game_session_fixture(%{host: user, status: :finished})
    conn = Phoenix.ConnTest.recycle(conn)

    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(conn, ~p"/game-history/#{session.id}")
  end
end
