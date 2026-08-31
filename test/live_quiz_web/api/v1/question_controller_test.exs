defmodule LiveQuizWeb.Api.V1.QuestionControllerTest do
  use LiveQuizWeb.ConnCase, async: true

  import Ecto.Query
  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import LiveQuiz.QuizzesFixtures

  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Quizzes
  alias LiveQuiz.Quizzes.AnswerOption
  alias LiveQuiz.Quizzes.Question
  alias LiveQuiz.Repo

  @unauthorized %{"errors" => %{"detail" => "Não autenticado"}}
  @not_found %{"errors" => %{"detail" => "Não encontrado"}}
  @invalid_direction %{"errors" => %{"detail" => ~s(A direção deve ser "up" ou "down")}}
  @limit_reached %{"errors" => %{"detail" => "Este quiz já atingiu o limite de 50 perguntas"}}
  @locked %{
    "errors" => %{"detail" => "Este quiz possui uma sala ativa e não pode ser alterado"}
  }

  setup :register_and_log_in_api_user

  setup %{conn: conn, scope: scope} do
    %{
      conn: put_req_header(conn, "accept", "application/json"),
      quiz: quiz_fixture(scope),
      other_scope: user_scope_fixture()
    }
  end

  describe "authentication" do
    test "every action answers 401 without a token", %{scope: scope, quiz: quiz} do
      question = question_fixture(scope, quiz)
      anonymous = build_conn()
      body = payload()

      responses = [
        get(anonymous, ~p"/api/v1/quizzes/#{quiz.id}/questions"),
        get(anonymous, ~p"/api/v1/quizzes/#{quiz.id}/questions/#{question.id}"),
        post(anonymous, ~p"/api/v1/quizzes/#{quiz.id}/questions", body),
        put(anonymous, ~p"/api/v1/quizzes/#{quiz.id}/questions/#{question.id}", body),
        patch(anonymous, ~p"/api/v1/quizzes/#{quiz.id}/questions/#{question.id}", body),
        delete(anonymous, ~p"/api/v1/quizzes/#{quiz.id}/questions/#{question.id}"),
        patch(anonymous, ~p"/api/v1/quizzes/#{quiz.id}/questions/#{question.id}/move", %{
          "direction" => "up"
        })
      ]

      for response <- responses do
        assert json_response(response, 401) == @unauthorized
      end

      assert Repo.get(Question, question.id)
      assert stored_count(quiz) == 1
    end
  end

  describe "ownership" do
    test "every action answers 404 for a quiz of somebody else", %{
      conn: conn,
      other_scope: other_scope
    } do
      theirs = quiz_fixture(other_scope)
      question = question_fixture(other_scope, theirs)
      body = payload()

      responses = [
        get(conn, ~p"/api/v1/quizzes/#{theirs.id}/questions"),
        get(recycle_json(conn), ~p"/api/v1/quizzes/#{theirs.id}/questions/#{question.id}"),
        post(recycle_json(conn), ~p"/api/v1/quizzes/#{theirs.id}/questions", body),
        put(recycle_json(conn), ~p"/api/v1/quizzes/#{theirs.id}/questions/#{question.id}", body),
        delete(recycle_json(conn), ~p"/api/v1/quizzes/#{theirs.id}/questions/#{question.id}"),
        patch(
          recycle_json(conn),
          ~p"/api/v1/quizzes/#{theirs.id}/questions/#{question.id}/move",
          %{"direction" => "up"}
        )
      ]

      for response <- responses do
        assert json_response(response, 404) == @not_found
      end

      assert stored_count(theirs) == 1
      assert Repo.get!(Question, question.id).text == question.text
    end

    test "answers 404 for a question that lives in another quiz", %{
      conn: conn,
      scope: scope,
      quiz: quiz,
      other_scope: other_scope
    } do
      theirs = quiz_fixture(other_scope)
      question = question_fixture(other_scope, theirs)

      mine = question_fixture(scope, quiz_fixture(scope, %{title: "Outro quiz meu"}))

      for id <- [question.id, mine.id] do
        assert conn
               |> recycle_json()
               |> get(~p"/api/v1/quizzes/#{quiz.id}/questions/#{id}")
               |> json_response(404) == @not_found
      end
    end
  end

  describe "GET /api/v1/quizzes/:quiz_id/questions" do
    test "lists the questions ordered by position, each with its answer options", %{
      conn: conn,
      scope: scope,
      quiz: quiz
    } do
      first = question_fixture(scope, quiz, %{text: "Qual é a capital do Brasil?"})
      second = question_fixture(scope, quiz, %{text: "Qual é a capital da França?"})
      third = question_fixture(scope, quiz, %{text: "Qual é a capital do Japão?"})

      conn = get(conn, ~p"/api/v1/quizzes/#{quiz.id}/questions")

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.map(data, & &1["id"]) == [first.id, second.id, third.id]
      assert Enum.map(data, & &1["position"]) == [1, 2, 3]

      assert [entry | _rest] = data
      assert entry["text"] == "Qual é a capital do Brasil?"
      assert Enum.map(entry["answer_options"], & &1["position"]) == [1, 2, 3, 4]
      assert [correct] = Enum.filter(entry["answer_options"], & &1["is_correct"])
      assert correct["text"] == "Brasília"
    end

    test "answers with an empty list for a quiz without questions", %{conn: conn, quiz: quiz} do
      conn = get(conn, ~p"/api/v1/quizzes/#{quiz.id}/questions")

      assert json_response(conn, 200) == %{"data" => []}
    end

    test "answers 404 for a quiz that does not exist", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/quizzes/0/questions")

      assert json_response(conn, 404) == @not_found
    end
  end

  describe "GET /api/v1/quizzes/:quiz_id/questions/:id" do
    test "returns the question with its answer options", %{conn: conn, scope: scope, quiz: quiz} do
      question = question_fixture(scope, quiz)

      conn = get(conn, ~p"/api/v1/quizzes/#{quiz.id}/questions/#{question.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == question.id
      assert data["text"] == question.text
      assert data["position"] == 1
      assert Enum.map(data["answer_options"], & &1["position"]) == [1, 2, 3, 4]
    end

    test "answers 404 for a question that does not exist", %{conn: conn, quiz: quiz} do
      conn = get(conn, ~p"/api/v1/quizzes/#{quiz.id}/questions/0")

      assert json_response(conn, 404) == @not_found
    end
  end

  describe "POST /api/v1/quizzes/:quiz_id/questions" do
    test "creates the question at the end of the quiz and points Location at it", %{
      conn: conn,
      quiz: quiz
    } do
      conn = post(conn, ~p"/api/v1/quizzes/#{quiz.id}/questions", payload())

      assert %{"data" => data} = json_response(conn, 201)
      assert data["text"] == "Qual é a capital do Brasil?"
      assert data["position"] == 1

      assert Enum.map(data["answer_options"], & &1["position"]) == [1, 2, 3, 4]

      assert Enum.map(data["answer_options"], & &1["text"]) ==
               ["Rio de Janeiro", "Brasília", "São Paulo", "Salvador"]

      assert [correct] = Enum.filter(data["answer_options"], & &1["is_correct"])
      assert correct["text"] == "Brasília"

      assert [location] = get_resp_header(conn, "location")
      assert location == "/api/v1/quizzes/#{quiz.id}/questions/#{data["id"]}"

      assert Repo.get!(Question, data["id"]).quiz_id == quiz.id
    end

    test "appends the new question after the existing ones", %{
      conn: conn,
      scope: scope,
      quiz: quiz
    } do
      question_fixture(scope, quiz)

      conn = post(conn, ~p"/api/v1/quizzes/#{quiz.id}/questions", payload())

      assert json_response(conn, 201)["data"]["position"] == 2
    end

    test "ignores a position sent by the client", %{conn: conn, quiz: quiz} do
      conn = post(conn, ~p"/api/v1/quizzes/#{quiz.id}/questions", payload(%{"position" => 99}))

      assert %{"data" => data} = json_response(conn, 201)
      assert data["position"] == 1
      assert Repo.get!(Question, data["id"]).position == 1
    end

    test "answers 422 without a correct answer option, writing nothing", %{
      conn: conn,
      quiz: quiz
    } do
      options = Enum.map(valid_options(), &Map.put(&1, "is_correct", false))

      conn =
        post(
          conn,
          ~p"/api/v1/quizzes/#{quiz.id}/questions",
          payload(%{"answer_options" => options})
        )

      assert json_response(conn, 422) == %{
               "errors" => %{"answer_options" => ["marque a alternativa correta"]}
             }

      assert stored_count(quiz) == 0
    end

    test "answers 422 with two correct answer options, writing nothing", %{
      conn: conn,
      quiz: quiz
    } do
      options =
        valid_options()
        |> List.update_at(0, &Map.put(&1, "is_correct", true))

      conn =
        post(
          conn,
          ~p"/api/v1/quizzes/#{quiz.id}/questions",
          payload(%{"answer_options" => options})
        )

      assert json_response(conn, 422) == %{
               "errors" => %{"answer_options" => ["marque apenas uma alternativa correta"]}
             }

      assert stored_count(quiz) == 0
    end

    test "answers 422 with three answer options, writing nothing", %{conn: conn, quiz: quiz} do
      options = Enum.take(valid_options(), 3)

      conn =
        post(
          conn,
          ~p"/api/v1/quizzes/#{quiz.id}/questions",
          payload(%{"answer_options" => options})
        )

      assert json_response(conn, 422) == %{
               "errors" => %{
                 "answer_options" => ["a pergunta deve ter exatamente 4 alternativas"]
               }
             }

      assert stored_count(quiz) == 0
    end

    test "answers 422 with repeated answer option texts, writing nothing", %{
      conn: conn,
      quiz: quiz
    } do
      options = List.update_at(valid_options(), 2, &Map.put(&1, "text", "brasília"))

      conn =
        post(
          conn,
          ~p"/api/v1/quizzes/#{quiz.id}/questions",
          payload(%{"answer_options" => options})
        )

      assert json_response(conn, 422) == %{
               "errors" => %{
                 "answer_options" => ["as alternativas não podem ter textos repetidos"]
               }
             }

      assert stored_count(quiz) == 0
    end

    test "answers 422 for an invalid question text, writing nothing", %{conn: conn, quiz: quiz} do
      conn = post(conn, ~p"/api/v1/quizzes/#{quiz.id}/questions", payload(%{"text" => "  "}))

      assert %{"errors" => errors} = json_response(conn, 422)
      assert Map.has_key?(errors, "text")
      assert stored_count(quiz) == 0
    end

    test "answers 422 when the body does not carry a question", %{conn: conn, quiz: quiz} do
      conn = post(conn, ~p"/api/v1/quizzes/#{quiz.id}/questions", %{"text" => "Fora do envelope"})

      assert %{"errors" => errors} = json_response(conn, 422)
      assert Map.has_key?(errors, "text")
      assert stored_count(quiz) == 0
    end

    test "answers 422 once the quiz reaches the question limit", %{
      conn: conn,
      scope: scope,
      quiz: quiz
    } do
      fill_quiz(scope, quiz, Quizzes.max_questions())

      conn = post(conn, ~p"/api/v1/quizzes/#{quiz.id}/questions", payload())

      assert json_response(conn, 422) == @limit_reached
      assert stored_count(quiz) == Quizzes.max_questions()
    end
  end

  describe "PUT and PATCH /api/v1/quizzes/:quiz_id/questions/:id" do
    test "updates the text and the correct option, keeping the ids and the position", %{
      conn: conn,
      scope: scope,
      quiz: quiz
    } do
      question_fixture(scope, quiz)
      question = question_fixture(scope, quiz)
      stored = Quizzes.get_question!(scope, quiz, question.id)
      option_ids = Enum.map(stored.answer_options, & &1.id)

      options =
        stored.answer_options
        |> Enum.map(
          &%{
            "id" => &1.id,
            "text" => &1.text,
            "position" => &1.position,
            "is_correct" => &1.position == 4
          }
        )

      body = payload(%{"text" => "Qual é a capital da Bahia?", "answer_options" => options})

      conn = put(conn, ~p"/api/v1/quizzes/#{quiz.id}/questions/#{question.id}", body)

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == question.id
      assert data["text"] == "Qual é a capital da Bahia?"
      assert data["position"] == 2
      assert Enum.map(data["answer_options"], & &1["id"]) == option_ids

      assert [correct] = Enum.filter(data["answer_options"], & &1["is_correct"])
      assert correct["position"] == 4

      reloaded = Quizzes.get_question!(scope, quiz, question.id)
      assert reloaded.position == 2

      assert Enum.filter(reloaded.answer_options, & &1.is_correct) |> Enum.map(& &1.position) == [
               4
             ]
    end

    test "updates through PATCH as well", %{conn: conn, scope: scope, quiz: quiz} do
      question = question_fixture(scope, quiz)

      conn =
        patch(conn, ~p"/api/v1/quizzes/#{quiz.id}/questions/#{question.id}", %{
          "question" => %{"text" => "Qual é a capital do Peru?"}
        })

      assert json_response(conn, 200)["data"]["text"] == "Qual é a capital do Peru?"
      assert Repo.get!(Question, question.id).text == "Qual é a capital do Peru?"
    end

    test "ignores a position sent by the client", %{conn: conn, scope: scope, quiz: quiz} do
      question_fixture(scope, quiz)
      question = question_fixture(scope, quiz)

      conn =
        patch(conn, ~p"/api/v1/quizzes/#{quiz.id}/questions/#{question.id}", %{
          "question" => %{"text" => "Qual é a capital do Peru?", "position" => 1}
        })

      assert json_response(conn, 200)["data"]["position"] == 2
      assert Repo.get!(Question, question.id).position == 2
    end

    test "answers 422 for an invalid set of answer options, changing nothing", %{
      conn: conn,
      scope: scope,
      quiz: quiz
    } do
      question = question_fixture(scope, quiz)
      stored = Quizzes.get_question!(scope, quiz, question.id)

      options =
        Enum.map(
          stored.answer_options,
          &%{"id" => &1.id, "text" => &1.text, "is_correct" => true}
        )

      body = payload(%{"text" => "Qual é a capital da Bahia?", "answer_options" => options})

      conn = put(conn, ~p"/api/v1/quizzes/#{quiz.id}/questions/#{question.id}", body)

      assert json_response(conn, 422) == %{
               "errors" => %{"answer_options" => ["marque apenas uma alternativa correta"]}
             }

      reloaded = Quizzes.get_question!(scope, quiz, question.id)
      assert reloaded.text == question.text
      assert Enum.count(reloaded.answer_options, & &1.is_correct) == 1
    end

    test "answers 404 for a question that does not exist", %{conn: conn, quiz: quiz} do
      conn = put(conn, ~p"/api/v1/quizzes/#{quiz.id}/questions/0", payload())

      assert json_response(conn, 404) == @not_found
    end
  end

  describe "PATCH /api/v1/quizzes/:quiz_id/questions/:id/move" do
    setup %{scope: scope, quiz: quiz} do
      %{
        first: question_fixture(scope, quiz, %{text: "Pergunta A"}),
        second: question_fixture(scope, quiz, %{text: "Pergunta B"}),
        third: question_fixture(scope, quiz, %{text: "Pergunta C"})
      }
    end

    test "moves a question up and answers with the whole reordered list", %{
      conn: conn,
      quiz: quiz,
      first: first,
      second: second,
      third: third
    } do
      conn = move(conn, quiz, second, "up")

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.map(data, & &1["id"]) == [second.id, first.id, third.id]
      assert Enum.map(data, & &1["position"]) == [1, 2, 3]
      assert Enum.map(hd(data)["answer_options"], & &1["position"]) == [1, 2, 3, 4]
    end

    test "moves a question down", %{
      conn: conn,
      quiz: quiz,
      first: first,
      second: second,
      third: third
    } do
      conn = move(conn, quiz, second, "down")

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.map(data, & &1["id"]) == [first.id, third.id, second.id]
      assert Enum.map(data, & &1["position"]) == [1, 2, 3]
    end

    test "answers 200 with the list unchanged when the question is already at the edge", %{
      conn: conn,
      quiz: quiz,
      first: first,
      second: second,
      third: third
    } do
      up = move(conn, quiz, first, "up")

      assert Enum.map(json_response(up, 200)["data"], & &1["id"]) == [
               first.id,
               second.id,
               third.id
             ]

      down = move(recycle_json(conn), quiz, third, "down")

      assert Enum.map(json_response(down, 200)["data"], & &1["id"]) ==
               [first.id, second.id, third.id]
    end

    test "answers 422 for a direction that is neither up nor down", %{
      conn: conn,
      quiz: quiz,
      first: first,
      second: second,
      third: third
    } do
      conn = move(conn, quiz, second, "left")

      assert json_response(conn, 422) == @invalid_direction
      assert stored_order(quiz) == [first.id, second.id, third.id]
    end

    test "answers 422 when the direction is missing", %{conn: conn, quiz: quiz, second: second} do
      conn = patch(conn, ~p"/api/v1/quizzes/#{quiz.id}/questions/#{second.id}/move", %{})

      assert json_response(conn, 422) == @invalid_direction
    end
  end

  describe "DELETE /api/v1/quizzes/:quiz_id/questions/:id" do
    test "answers 204, removes the answer options and renumbers the remaining questions", %{
      conn: conn,
      scope: scope,
      quiz: quiz
    } do
      first = question_fixture(scope, quiz, %{text: "Pergunta A"})
      second = question_fixture(scope, quiz, %{text: "Pergunta B"})
      third = question_fixture(scope, quiz, %{text: "Pergunta C"})

      conn = delete(conn, ~p"/api/v1/quizzes/#{quiz.id}/questions/#{second.id}")

      assert response(conn, 204) == ""
      refute Repo.get(Question, second.id)
      assert Repo.aggregate(where(AnswerOption, question_id: ^second.id), :count) == 0

      assert stored_order(quiz) == [first.id, third.id]
      assert Repo.get!(Question, first.id).position == 1
      assert Repo.get!(Question, third.id).position == 2
    end

    test "answers 404 for a question that does not exist", %{conn: conn, quiz: quiz} do
      conn = delete(conn, ~p"/api/v1/quizzes/#{quiz.id}/questions/0")

      assert json_response(conn, 404) == @not_found
    end
  end

  describe "quiz com sala ativa" do
    setup %{scope: scope, quiz: quiz} do
      first = question_fixture(scope, quiz, %{text: "Primeira pergunta?"})
      second = question_fixture(scope, quiz, %{text: "Segunda pergunta?"})

      %{
        first: first,
        second: second,
        session: game_session_fixture(%{quiz: quiz, status: :waiting})
      }
    end

    test "POST responde 409 e nada é gravado", %{conn: conn, quiz: quiz} do
      conn = post(conn, ~p"/api/v1/quizzes/#{quiz.id}/questions", payload())

      assert json_response(conn, 409) == @locked
      assert stored_count(quiz) == 2
    end

    test "PUT responde 409 e a pergunta fica como estava", %{
      conn: conn,
      quiz: quiz,
      first: first
    } do
      conn =
        put(
          conn,
          ~p"/api/v1/quizzes/#{quiz.id}/questions/#{first.id}",
          payload(%{"text" => "Trocada?"})
        )

      assert json_response(conn, 409) == @locked
      assert Repo.get!(Question, first.id).text == "Primeira pergunta?"
    end

    test "PATCH responde 409", %{conn: conn, quiz: quiz, first: first} do
      conn =
        patch(
          conn,
          ~p"/api/v1/quizzes/#{quiz.id}/questions/#{first.id}",
          payload(%{"text" => "Trocada?"})
        )

      assert json_response(conn, 409) == @locked
    end

    test "DELETE responde 409 e a pergunta continua existindo", %{
      conn: conn,
      quiz: quiz,
      first: first
    } do
      conn = delete(conn, ~p"/api/v1/quizzes/#{quiz.id}/questions/#{first.id}")

      assert json_response(conn, 409) == @locked
      assert Repo.get(Question, first.id)
      assert stored_count(quiz) == 2
    end

    test "move responde 409 e a ordem não muda", %{
      conn: conn,
      quiz: quiz,
      first: first,
      second: second
    } do
      conn = move(conn, quiz, second, "up")

      assert json_response(conn, 409) == @locked
      assert stored_order(quiz) == [first.id, second.id]
    end

    test "GET da listagem continua respondendo 200", %{conn: conn, quiz: quiz} do
      assert %{"data" => data} =
               conn |> get(~p"/api/v1/quizzes/#{quiz.id}/questions") |> json_response(200)

      assert length(data) == 2
    end

    test "volta a aceitar a criação depois que a sala é encerrada", %{
      conn: conn,
      quiz: quiz,
      session: session
    } do
      close!(session)

      conn = post(conn, ~p"/api/v1/quizzes/#{quiz.id}/questions", payload())

      assert %{"data" => _data} = json_response(conn, 201)
      assert stored_count(quiz) == 3
    end

    test "volta a aceitar a exclusão depois que a sala expira", %{
      conn: conn,
      quiz: quiz,
      first: first,
      session: session
    } do
      close!(session, :expired)

      assert response(delete(conn, ~p"/api/v1/quizzes/#{quiz.id}/questions/#{first.id}"), 204) ==
               ""

      refute Repo.get(Question, first.id)
    end

    test "o 404 tem precedência sobre o 409 para o quiz de outro dono", %{
      conn: conn,
      other_scope: other_scope
    } do
      theirs = quiz_fixture(other_scope)
      question = question_fixture(other_scope, theirs)
      game_session_fixture(%{quiz: theirs, status: :waiting})

      assert json_response(post(conn, ~p"/api/v1/quizzes/#{theirs.id}/questions", payload()), 404) ==
               @not_found

      assert json_response(
               delete(conn, ~p"/api/v1/quizzes/#{theirs.id}/questions/#{question.id}"),
               404
             ) == @not_found

      assert Repo.get(Question, question.id)
    end
  end

  defp close!(%GameSession{} = session, status \\ :cancelled) do
    session
    |> GameSession.status_changeset(status)
    |> Repo.update!()
  end

  defp move(conn, quiz, question, direction) do
    patch(conn, ~p"/api/v1/quizzes/#{quiz.id}/questions/#{question.id}/move", %{
      "direction" => direction
    })
  end

  defp recycle_json(conn) do
    conn |> recycle() |> put_req_header("accept", "application/json")
  end

  defp valid_options do
    [
      %{"text" => "Rio de Janeiro", "position" => 1, "is_correct" => false},
      %{"text" => "Brasília", "position" => 2, "is_correct" => true},
      %{"text" => "São Paulo", "position" => 3, "is_correct" => false},
      %{"text" => "Salvador", "position" => 4, "is_correct" => false}
    ]
  end

  defp payload(attrs \\ %{}) do
    question =
      Map.merge(
        %{"text" => "Qual é a capital do Brasil?", "answer_options" => valid_options()},
        attrs
      )

    %{"question" => question}
  end

  defp fill_quiz(scope, quiz, count) do
    for index <- 1..count do
      question_fixture(scope, quiz, %{
        text: "Pergunta número #{index}",
        answer_options: [
          %{text: "Alternativa A da #{index}", position: 1, is_correct: true},
          %{text: "Alternativa B da #{index}", position: 2, is_correct: false},
          %{text: "Alternativa C da #{index}", position: 3, is_correct: false},
          %{text: "Alternativa D da #{index}", position: 4, is_correct: false}
        ]
      })
    end
  end

  defp stored_count(quiz) do
    Repo.aggregate(where(Question, quiz_id: ^quiz.id), :count)
  end

  defp stored_order(quiz) do
    Repo.all(from q in Question, where: q.quiz_id == ^quiz.id, order_by: q.position, select: q.id)
  end
end
