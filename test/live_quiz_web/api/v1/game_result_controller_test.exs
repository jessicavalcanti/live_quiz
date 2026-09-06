defmodule LiveQuizWeb.Api.V1.GameResultControllerTest do
  use LiveQuizWeb.ConnCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games

  setup :register_and_log_in_api_user

  setup %{conn: conn} do
    %{conn: put_req_header(conn, "accept", "application/json")}
  end

  setup %{user: user} do
    session = game_session_fixture(%{host: user, status: :in_progress})
    participant = participant_fixture(session, %{user: user, nickname: "Jogador"})
    {:ok, finished} = Games.finish_game_session(Scope.for_user(user), session)
    %{session: finished, participant: participant}
  end

  test "serves ranking, complete result and own result", %{
    conn: conn,
    session: session,
    participant: participant
  } do
    assert %{"data" => [%{"participant_id" => id, "position" => 1}]} =
             conn
             |> get(~p"/api/v1/game-sessions/#{session.join_code}/ranking")
             |> json_response(200)

    assert id == participant.id

    assert %{"data" => %{"results" => [%{"participant_id" => ^id}]}} =
             conn
             |> get(~p"/api/v1/game-sessions/#{session.join_code}/results")
             |> json_response(200)

    assert %{"data" => %{"participant_id" => ^id}} =
             conn
             |> get(~p"/api/v1/game-sessions/#{session.join_code}/results/me")
             |> json_response(200)
  end

  test "serves personal and quiz histories with pagination and filters", %{
    conn: conn,
    session: session
  } do
    personal =
      get(conn, ~p"/api/v1/users/me/game-results?page=1&per_page=1") |> json_response(200)

    assert personal["meta"] == %{
             "page" => 1,
             "per_page" => 1,
             "total_entries" => 1,
             "total_pages" => 1
           }

    assert hd(personal["data"])["game_session_id"] == session.id

    history =
      get(conn, ~p"/api/v1/quizzes/#{session.quiz_id}/game-history?from=2020-01-01&to=2099-12-31")
      |> json_response(200)

    assert history["meta"]["total_entries"] == 1
    assert hd(history["data"])["id"] == session.id
  end

  test "rejects invalid filters and protects results from another user", %{
    conn: conn,
    session: session
  } do
    assert json_response(get(conn, ~p"/api/v1/users/me/game-results?per_page=101"), 422) == %{
             "errors" => %{
               "code" => "invalid_filter",
               "detail" => "Filtros e paginação inválidos"
             }
           }

    other = user_fixture()
    other_conn = conn |> recycle() |> log_in_api_user(other)

    assert json_response(
             get(other_conn, ~p"/api/v1/game-sessions/#{session.join_code}/results"),
             404
           ) == %{
             "errors" => %{"detail" => "Não encontrado"}
           }
  end

  test "requires an account token for result endpoints", %{session: session} do
    conn = build_conn() |> put_req_header("accept", "application/json")

    assert json_response(
             get(conn, ~p"/api/v1/game-sessions/#{session.join_code}/results/me"),
             401
           ) == %{
             "errors" => %{"detail" => "Não autenticado"}
           }
  end
end
