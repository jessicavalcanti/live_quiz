defmodule LiveQuizWeb.Api.V1.QuizControllerTest do
  use LiveQuizWeb.ConnCase, async: true

  import Ecto.Query
  import LiveQuiz.AccountsFixtures
  import LiveQuiz.QuizzesFixtures

  alias LiveQuiz.Quizzes.AnswerOption
  alias LiveQuiz.Quizzes.Question
  alias LiveQuiz.Quizzes.Quiz
  alias LiveQuiz.Repo

  @unauthorized %{"errors" => %{"detail" => "Não autenticado"}}
  @not_found %{"errors" => %{"detail" => "Não encontrado"}}

  setup :register_and_log_in_api_user

  setup %{conn: conn} do
    %{conn: put_req_header(conn, "accept", "application/json"), other_scope: user_scope_fixture()}
  end

  describe "authentication" do
    test "every action answers 401 without a token", %{scope: scope} do
      quiz = quiz_fixture(scope)
      anonymous = build_conn()

      responses = [
        get(anonymous, ~p"/api/v1/quizzes"),
        get(anonymous, ~p"/api/v1/quizzes/#{quiz.id}"),
        post(anonymous, ~p"/api/v1/quizzes", %{"quiz" => %{"title" => "Geografia"}}),
        put(anonymous, ~p"/api/v1/quizzes/#{quiz.id}", %{"quiz" => %{"title" => "Geografia"}}),
        patch(anonymous, ~p"/api/v1/quizzes/#{quiz.id}", %{"quiz" => %{"title" => "Geografia"}}),
        delete(anonymous, ~p"/api/v1/quizzes/#{quiz.id}")
      ]

      for response <- responses do
        assert json_response(response, 401) == @unauthorized
      end

      assert Repo.get(Quiz, quiz.id)
    end

    test "a refresh token is not accepted as an access token", %{conn: conn, user: user} do
      conn =
        conn
        |> recycle()
        |> log_in_api_user(user, token_type: "refresh")
        |> get(~p"/api/v1/quizzes")

      assert json_response(conn, 401) == @unauthorized
    end
  end

  describe "GET /api/v1/quizzes" do
    test "lists the quizzes of the token owner with the pagination metadata", %{
      conn: conn,
      scope: scope
    } do
      first = quiz_fixture(scope, %{title: "Geografia"})
      second = quiz_fixture(scope, %{title: "História"})

      conn = get(conn, ~p"/api/v1/quizzes")

      assert %{"data" => data, "meta" => meta} = json_response(conn, 200)

      ids = data |> Enum.map(& &1["id"]) |> Enum.sort()
      assert ids == Enum.sort([first.id, second.id])

      assert meta == %{
               "page" => 1,
               "per_page" => 20,
               "total_entries" => 2,
               "total_pages" => 1
             }
    end

    test "serializes questions_count and playable, without nesting the questions", %{
      conn: conn,
      scope: scope
    } do
      quiz = quiz_fixture(scope, %{title: "Geografia", description: "Capitais"})
      question_fixture(scope, quiz)

      conn = get(conn, ~p"/api/v1/quizzes")

      assert %{"data" => [entry]} = json_response(conn, 200)

      assert entry["id"] == quiz.id
      assert entry["title"] == "Geografia"
      assert entry["description"] == "Capitais"
      assert entry["questions_count"] == 1
      assert entry["playable"] == true
      assert entry["inserted_at"] == DateTime.to_iso8601(quiz.inserted_at)
      assert entry["updated_at"] == DateTime.to_iso8601(quiz.updated_at)
      refute Map.has_key?(entry, "questions")
    end

    test "never shows the quizzes of somebody else", %{
      conn: conn,
      scope: scope,
      other_scope: other_scope
    } do
      mine = quiz_fixture(scope, %{title: "Meu"})
      theirs = quiz_fixture(other_scope, %{title: "Do Bruno"})

      conn = get(conn, ~p"/api/v1/quizzes")

      assert %{"data" => data, "meta" => meta} = json_response(conn, 200)
      assert Enum.map(data, & &1["id"]) == [mine.id]
      refute theirs.id in Enum.map(data, & &1["id"])
      assert meta["total_entries"] == 1
    end

    test "answers with an empty page when there is no quiz", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/quizzes")

      assert json_response(conn, 200) == %{
               "data" => [],
               "meta" => %{
                 "page" => 1,
                 "per_page" => 20,
                 "total_entries" => 0,
                 "total_pages" => 0
               }
             }
    end

    test "respects page and per_page", %{conn: conn, scope: scope} do
      for index <- 1..25, do: quiz_fixture(scope, %{title: "Quiz #{index}"})

      conn = get(conn, ~p"/api/v1/quizzes?page=2&per_page=20")

      assert %{"data" => data, "meta" => meta} = json_response(conn, 200)
      assert length(data) == 5
      assert meta["page"] == 2
      assert meta["per_page"] == 20
      assert meta["total_entries"] == 25
      assert meta["total_pages"] == 2
    end

    test "accepts a per_page of 100 and refuses to go past it", %{conn: conn, scope: scope} do
      quiz_fixture(scope)

      at_the_ceiling = get(conn, ~p"/api/v1/quizzes?per_page=100")
      assert json_response(at_the_ceiling, 200)["meta"]["per_page"] == 100

      past_the_ceiling = get(recycle(conn), ~p"/api/v1/quizzes?per_page=101")
      assert json_response(past_the_ceiling, 200)["meta"]["per_page"] == 20
    end

    test "falls back to the defaults when the pagination is not a number", %{
      conn: conn,
      scope: scope
    } do
      quiz_fixture(scope)

      conn = get(conn, ~p"/api/v1/quizzes?page=abc&per_page=-3")

      assert json_response(conn, 200)["meta"] == %{
               "page" => 1,
               "per_page" => 20,
               "total_entries" => 1,
               "total_pages" => 1
             }
    end

    test "filters by search, ignoring case and blank terms", %{conn: conn, scope: scope} do
      geography = quiz_fixture(scope, %{title: "Geografia"})
      quiz_fixture(scope, %{title: "História"})

      found = get(conn, ~p"/api/v1/quizzes?search=geo")

      assert %{"data" => [entry], "meta" => meta} = json_response(found, 200)
      assert entry["id"] == geography.id
      assert meta["total_entries"] == 1

      blank = get(recycle(conn), ~p"/api/v1/quizzes?search=%20")
      assert length(json_response(blank, 200)["data"]) == 2
    end
  end

  describe "GET /api/v1/quizzes/:id" do
    test "returns the quiz with its questions and answer options in order", %{
      conn: conn,
      scope: scope
    } do
      quiz = quiz_fixture(scope, %{title: "Geografia"})
      first = question_fixture(scope, quiz, %{text: "Qual é a capital do Brasil?"})
      second = question_fixture(scope, quiz, %{text: "Qual é a capital da França?"})

      conn = get(conn, ~p"/api/v1/quizzes/#{quiz.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == quiz.id
      assert data["questions_count"] == 2
      assert data["playable"] == true

      assert [first_json, second_json] = data["questions"]
      assert first_json["id"] == first.id
      assert first_json["position"] == 1
      assert second_json["id"] == second.id
      assert second_json["position"] == 2

      assert Enum.map(first_json["answer_options"], & &1["position"]) == [1, 2, 3, 4]

      assert [correct] = Enum.filter(first_json["answer_options"], & &1["is_correct"])
      assert correct["text"] == "Brasília"
      assert correct["position"] == 1
    end

    test "returns questions_count 0 and playable false for a quiz without questions", %{
      conn: conn,
      scope: scope
    } do
      quiz = quiz_fixture(scope)

      conn = get(conn, ~p"/api/v1/quizzes/#{quiz.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["questions_count"] == 0
      assert data["playable"] == false
      assert data["questions"] == []
    end

    test "returns 404 for a quiz that does not exist", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/quizzes/0")

      assert json_response(conn, 404) == @not_found
    end

    test "returns 404 for a quiz of somebody else", %{conn: conn, other_scope: other_scope} do
      theirs = quiz_fixture(other_scope)

      conn = get(conn, ~p"/api/v1/quizzes/#{theirs.id}")

      assert json_response(conn, 404) == @not_found
    end
  end

  describe "POST /api/v1/quizzes" do
    test "creates the quiz and points the Location header at it", %{
      conn: conn,
      scope: scope
    } do
      attrs = %{"title" => "Geografia", "description" => "Capitais do mundo"}

      conn = post(conn, ~p"/api/v1/quizzes", %{"quiz" => attrs})

      assert %{"data" => data} = json_response(conn, 201)
      assert data["title"] == "Geografia"
      assert data["description"] == "Capitais do mundo"
      assert data["questions_count"] == 0
      assert data["playable"] == false

      assert [location] = get_resp_header(conn, "location")
      assert location == "/api/v1/quizzes/#{data["id"]}"

      quiz = Repo.get!(Quiz, data["id"])
      assert quiz.owner_id == scope.user.id
    end

    test "ignores an owner_id smuggled in through the body", %{
      conn: conn,
      scope: scope,
      other_scope: other_scope
    } do
      attrs = %{"title" => "Geografia", "owner_id" => other_scope.user.id}

      conn = post(conn, ~p"/api/v1/quizzes", %{"quiz" => attrs})

      assert %{"data" => data} = json_response(conn, 201)
      assert Repo.get!(Quiz, data["id"]).owner_id == scope.user.id
    end

    test "returns 422 with the field errors when the title is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/quizzes", %{"quiz" => %{"description" => "Sem título"}})

      assert json_response(conn, 422) == %{
               "errors" => %{"title" => ["não pode ficar em branco"]}
             }
    end

    test "returns 422 when the body does not carry a quiz", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/quizzes", %{"title" => "Fora do envelope"})

      assert %{"errors" => %{"title" => _messages}} = json_response(conn, 422)
    end
  end

  describe "PATCH and PUT /api/v1/quizzes/:id" do
    test "updates the quiz through PATCH", %{conn: conn, scope: scope} do
      quiz = quiz_fixture(scope, %{title: "Geografia"})

      conn =
        patch(conn, ~p"/api/v1/quizzes/#{quiz.id}", %{"quiz" => %{"title" => "Geografia II"}})

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == quiz.id
      assert data["title"] == "Geografia II"
      assert Repo.get!(Quiz, quiz.id).title == "Geografia II"
    end

    test "updates the quiz through PUT, keeping the questions in the payload", %{
      conn: conn,
      scope: scope
    } do
      quiz = quiz_fixture(scope, %{title: "Geografia"})
      question = question_fixture(scope, quiz)

      conn = put(conn, ~p"/api/v1/quizzes/#{quiz.id}", %{"quiz" => %{"title" => "Geografia II"}})

      assert %{"data" => data} = json_response(conn, 200)
      assert data["title"] == "Geografia II"
      assert data["questions_count"] == 1
      assert data["playable"] == true
      assert [question_json] = data["questions"]
      assert question_json["id"] == question.id
    end

    test "returns 422 when the new title is invalid", %{conn: conn, scope: scope} do
      quiz = quiz_fixture(scope, %{title: "Geografia"})

      conn = patch(conn, ~p"/api/v1/quizzes/#{quiz.id}", %{"quiz" => %{"title" => "  "}})

      assert %{"errors" => %{"title" => _messages}} = json_response(conn, 422)
      assert Repo.get!(Quiz, quiz.id).title == "Geografia"
    end

    test "returns 404 for a quiz of somebody else", %{conn: conn, other_scope: other_scope} do
      theirs = quiz_fixture(other_scope, %{title: "Do Bruno"})

      conn = patch(conn, ~p"/api/v1/quizzes/#{theirs.id}", %{"quiz" => %{"title" => "Roubado"}})

      assert json_response(conn, 404) == @not_found
      assert Repo.get!(Quiz, theirs.id).title == "Do Bruno"
    end
  end

  describe "DELETE /api/v1/quizzes/:id" do
    test "answers 204 and removes the quiz with its questions and options", %{
      conn: conn,
      scope: scope
    } do
      quiz = quiz_fixture(scope)
      question = question_fixture(scope, quiz)

      conn = delete(conn, ~p"/api/v1/quizzes/#{quiz.id}")

      assert response(conn, 204) == ""
      refute Repo.get(Quiz, quiz.id)
      refute Repo.get(Question, question.id)
      assert Repo.aggregate(where(AnswerOption, question_id: ^question.id), :count) == 0
    end

    test "returns 404 for a quiz of somebody else", %{conn: conn, other_scope: other_scope} do
      theirs = quiz_fixture(other_scope)

      conn = delete(conn, ~p"/api/v1/quizzes/#{theirs.id}")

      assert json_response(conn, 404) == @not_found
      assert Repo.get(Quiz, theirs.id)
    end
  end
end
