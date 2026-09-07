defmodule LiveQuizWeb.GameResultLive.ShowTest do
  use LiveQuizWeb.ConnCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import Phoenix.LiveViewTest

  alias LiveQuiz.Games.GameResult
  alias LiveQuiz.Repo

  setup :register_and_log_in_user

  test "shows the result summary, question details and São Paulo date", %{conn: conn, user: user} do
    session = game_session_fixture(%{host: user, status: :finished})
    participant = participant_fixture(session, %{user: user, released_at: now()})

    result =
      game_result_fixture(session, participant, %{
        question_results: %{
          "1" => %{
            "question" => "Capital?",
            "answer" => "Brasília",
            "correct" => true,
            "response_time_ms" => 1200
          }
        }
      })

    Repo.update_all(GameResult, set: [inserted_at: ~U[2026-08-30 02:30:00Z]])
    {:ok, _lv, html} = live(conn, ~p"/game-results/#{result.id}")

    assert html =~ "Capital?"
    assert html =~ "Brasília"
    assert html =~ "Correta"
    assert html =~ "29/08/2026 23:30"
    assert html =~ "Tempo médio"
  end

  test "does not expose another user's result", %{conn: conn} do
    other = user_fixture()
    session = game_session_fixture(%{host: other, status: :finished})
    participant = participant_fixture(session, %{user: other, released_at: now()})
    result = game_result_fixture(session, participant)

    assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/game-results/#{result.id}") end
  end

  test "requires authentication", %{conn: conn, user: user} do
    session = game_session_fixture(%{host: user, status: :finished})
    participant = participant_fixture(session, %{user: user, released_at: now()})
    result = game_result_fixture(session, participant)

    conn = Phoenix.ConnTest.recycle(conn)

    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(conn, ~p"/game-results/#{result.id}")
  end
end
