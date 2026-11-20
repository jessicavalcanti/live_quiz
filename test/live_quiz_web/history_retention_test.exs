defmodule LiveQuizWeb.HistoryRetentionTest do
  use LiveQuizWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games
  alias LiveQuiz.Repo

  test "finished history remains readable through web and API after host deletion", %{conn: conn} do
    host = user_fixture()
    player = user_fixture()
    session = game_session_fixture(%{host: host, status: :in_progress})
    participant = participant_fixture(session, %{user: player})
    [question] = snapshot_fixture(session, count: 1, played: 1)
    answer_fixture(participant, hd(question.answer_options))
    assert {:ok, finished} = Games.finish_game_session(Scope.for_user(host), session)

    assert {:ok, result} =
             Games.get_my_game_result_for_session(Scope.for_user(player), finished.id)

    Repo.delete!(host)

    web_conn = log_in_user(conn, player)
    assert {:ok, _, html} = live(web_conn, ~p"/game-results")
    assert html =~ result.quiz_title
    assert {:ok, _, html} = live(web_conn, ~p"/game-results/#{result.id}")
    assert html =~ question.text

    api_conn = conn |> log_in_api_user(player) |> put_req_header("accept", "application/json")
    response = api_conn |> get(~p"/api/v1/users/me/game-results") |> json_response(200)
    assert Enum.any?(response["data"], &(&1["game_session_id"] == session.id))

    response =
      api_conn
      |> get(~p"/api/v1/game-sessions/#{session.join_code}/results/me")
      |> json_response(200)

    assert response["data"]["participant_id"] == participant.id

    outsider_conn =
      conn |> log_in_api_user(user_fixture()) |> put_req_header("accept", "application/json")

    assert outsider_conn
           |> get(~p"/api/v1/game-sessions/#{session.join_code}/results/me")
           |> json_response(404)
  end
end
