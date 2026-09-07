defmodule LiveQuizWeb.Api.V1.ResultContractTest do
  @moduledoc """
  The bodies these endpoints really send, cast against the schemas that
  describe them.

  Regressions for R33 and R34 of the review. A controller test that asserts on
  a couple of keys passes while a generated client cannot read the body at all:
  `question_results` was declared an array and serialized a map, the aggregate
  result of a match reused the schema of a paginated listing, and `quiz_id`
  could be null against a declaration that said it never is.

  So these tests do the one thing the existing ones did not: take the JSON the
  endpoint answered and cast it through the schema the operation names.
  """

  use LiveQuizWeb.ConnCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import LiveQuiz.QuizzesFixtures

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games
  alias LiveQuiz.Quizzes
  alias LiveQuizWeb.ApiSpec

  setup :register_and_log_in_api_user

  describe "o resultado individual" do
    test "o corpo real passa pelo schema que o documenta", %{conn: conn, scope: scope} do
      %{session: session} = finished_match(scope)

      body =
        conn
        |> get(~p"/api/v1/game-sessions/#{session.join_code}/results/me")
        |> json_response(200)

      assert_valid(body, "GameResultResponse")
    end

    test "question_results é um mapa indexado pela posição, como o schema diz", %{
      conn: conn,
      scope: scope
    } do
      %{session: session} = finished_match(scope)

      %{"data" => data} =
        conn
        |> get(~p"/api/v1/game-sessions/#{session.join_code}/results/me")
        |> json_response(200)

      assert is_map(data["question_results"])
      refute is_list(data["question_results"])
      assert Map.keys(data["question_results"]) == ["1"]
    end

    test "quiz_id nulo depois de o quiz ser excluído continua válido", %{
      conn: conn,
      scope: scope
    } do
      %{session: session, quiz: quiz} = finished_match(scope)
      {:ok, _deleted} = Quizzes.delete_quiz(scope, quiz)

      body =
        conn
        |> get(~p"/api/v1/game-sessions/#{session.join_code}/results/me")
        |> json_response(200)

      assert body["data"]["quiz_id"] == nil
      assert_valid(body, "GameResultResponse")
    end
  end

  describe "o resultado agregado da partida" do
    test "o corpo real passa pelo schema próprio, não pelo de listagem", %{
      conn: conn,
      scope: scope
    } do
      %{session: session} = finished_match(scope)

      body =
        conn
        |> get(~p"/api/v1/game-sessions/#{session.join_code}/results")
        |> json_response(200)

      assert_valid(body, "GameSessionResultsResponse")

      # A forma que o schema antigo prometia: `data` como lista, com `meta`.
      assert is_map(body["data"])
      assert Map.has_key?(body["data"], "session")
      assert Map.has_key?(body["data"], "results")
      refute Map.has_key?(body, "meta")
    end
  end

  describe "o histórico de um quiz" do
    test "o quiz próprio sem partidas devolve lista vazia", %{conn: conn, scope: scope} do
      quiz = quiz_fixture(scope)

      body = conn |> get(~p"/api/v1/quizzes/#{quiz.id}/game-history") |> json_response(200)

      assert body["data"] == []
      assert_valid(body, "GameHistoryResponse")
    end

    test "o quiz de outra pessoa responde 404, não uma lista vazia", %{conn: conn} do
      foreign = quiz_fixture(user_scope_fixture())

      assert conn
             |> get(~p"/api/v1/quizzes/#{foreign.id}/game-history")
             |> json_response(404)
    end

    test "um quiz inexistente responde 404", %{conn: conn} do
      assert conn |> get(~p"/api/v1/quizzes/999999/game-history") |> json_response(404)
    end

    test "um identificador impossível responde 404", %{conn: conn} do
      assert conn |> get("/api/v1/quizzes/abc/game-history") |> json_response(404)
    end

    test "o corpo real do histórico passa pelo schema", %{conn: conn, scope: scope} do
      %{quiz: quiz} = finished_match(scope)

      body = conn |> get(~p"/api/v1/quizzes/#{quiz.id}/game-history") |> json_response(200)

      assert [entry] = body["data"]
      assert entry["status"] == "finished"
      assert_valid(body, "GameHistoryResponse")
    end
  end

  # Casts the body through the schema the operation names. A controller test
  # asserting on two keys says nothing about whether a generated client could
  # read the rest.
  defp assert_valid(body, schema_name) do
    spec = ApiSpec.spec()
    schema = Map.fetch!(spec.components.schemas, schema_name)

    case OpenApiSpex.cast_value(body, schema, spec) do
      {:ok, _cast} ->
        :ok

      {:error, errors} ->
        flunk("""
        o corpo real não passa pelo schema #{schema_name}:

        #{Enum.map_join(errors, "\n", &OpenApiSpex.Cast.Error.message/1)}
        """)
    end
  end

  defp finished_match(%Scope{} = scope) do
    quiz = quiz_fixture(scope, %{title: "Geografia"})
    question_fixture(scope, quiz)

    # The host is also the account asking, and `results/me` reads the result of
    # the *account*: the participation carries the user so there is one to find.
    session = game_session_fixture(%{host: scope.user, quiz: quiz, status: :in_progress})
    [snapshot] = snapshot_fixture(session, count: 1)
    participant = participant_fixture(session, %{user: scope.user})

    {:ok, opened} = Games.advance_question(scope, session, nil)
    Games.QuestionTimer.stop(opened.id)

    clock = LiveQuiz.Repo.get!(LiveQuiz.Games.GameSessionQuestion, snapshot.id)

    answer_fixture(participant, Enum.find(snapshot.answer_options, & &1.is_correct), %{
      answered_at: DateTime.add(clock.started_at, 1, :second)
    })

    {:ok, _finished} = Games.finish_game_session(scope, opened)

    %{session: session, participant: participant, quiz: quiz}
  end
end
