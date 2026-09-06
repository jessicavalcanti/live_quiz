defmodule LiveQuizWeb.QuizLive.EditorTest do
  use LiveQuizWeb.ConnCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.QuizzesFixtures
  import Phoenix.LiveViewTest

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Quizzes

  setup :register_and_log_in_user

  setup %{user: user} do
    scope = Scope.for_user(user)

    %{scope: scope, quiz: quiz_fixture(scope, %{title: "Geografia", description: "Capitais"})}
  end

  describe "route protection" do
    test "redirects a visitor to the log in page", %{quiz: quiz} do
      assert {:error, {:redirect, %{to: path}}} =
               live(build_conn(), ~p"/quizzes/#{quiz}/edit")

      assert path == ~p"/users/log-in"
    end

    test "answers 404 for a quiz of another user", %{conn: conn} do
      foreign = quiz_fixture(user_scope_fixture())

      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/quizzes/#{foreign}/edit") end
    end

    test "answers 404 for a quiz that does not exist", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/quizzes/0/edit") end
    end
  end

  describe "rendering" do
    test "loads the current title and description", %{conn: conn, quiz: quiz} do
      {:ok, _lv, html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      assert html =~ ~s(value="Geografia")
      assert html =~ "Capitais"
    end

    test "shows a breadcrumb back to the dashboard", %{conn: conn, quiz: quiz} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      assert lv |> element(~s{a[href="/quizzes"]}, "Meus quizzes") |> has_element?()
    end

    test "counts the remaining description characters", %{conn: conn, quiz: quiz} do
      {:ok, lv, html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      assert html =~ "492 caracteres restantes"

      html =
        lv
        |> form("#quiz-form", %{"quiz" => %{"description" => String.duplicate("a", 100)}})
        |> render_change()

      assert html =~ "400 caracteres restantes"
    end

    test "reports how many questions the quiz has", %{conn: conn, scope: scope, quiz: quiz} do
      {:ok, _lv, html} = live(conn, ~p"/quizzes/#{quiz}/edit")
      assert html =~ "ainda não tem perguntas"

      question_fixture(scope, quiz)

      {:ok, _lv, html} = live(conn, ~p"/quizzes/#{quiz}/edit")
      assert html =~ "1 pergunta."
    end
  end

  describe "saving" do
    test "persists a valid change and confirms it", %{conn: conn, scope: scope, quiz: quiz} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      html =
        lv
        |> form("#quiz-form", %{"quiz" => %{"title" => "Geografia do Brasil"}})
        |> render_submit()

      assert html =~ "Alterações salvas"
      assert Quizzes.get_quiz!(scope, quiz.id).title == "Geografia do Brasil"
    end

    test "the new title shows up on the dashboard", %{conn: conn, quiz: quiz} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      lv
      |> form("#quiz-form", %{"quiz" => %{"title" => "Geografia do Brasil"}})
      |> render_submit()

      {:ok, _index, html} = live(conn, ~p"/quizzes")

      assert html =~ "Geografia do Brasil"
    end

    test "rejects a blank title without persisting", %{conn: conn, scope: scope, quiz: quiz} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      html = lv |> form("#quiz-form", %{"quiz" => %{"title" => ""}}) |> render_submit()

      assert html =~ "não pode ficar em branco"
      assert Quizzes.get_quiz!(scope, quiz.id).title == "Geografia"
    end

    test "rejects a title that is too short", %{conn: conn, scope: scope, quiz: quiz} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      html = lv |> form("#quiz-form", %{"quiz" => %{"title" => "AB"}}) |> render_submit()

      assert html =~ "deve ter pelo menos 3 caracteres"
      assert Quizzes.get_quiz!(scope, quiz.id).title == "Geografia"
    end

    test "rejects a description that is too long", %{conn: conn, scope: scope, quiz: quiz} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      params = %{"quiz" => %{"description" => String.duplicate("a", 501)}}
      html = lv |> form("#quiz-form", params) |> render_submit()

      assert html =~ "deve ter no máximo 500 caracteres"
      assert Quizzes.get_quiz!(scope, quiz.id).description == "Capitais"
    end

    test "moves focus to the first field with an error", %{conn: conn, quiz: quiz} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      html = lv |> form("#quiz-form", %{"quiz" => %{"title" => ""}}) |> render_submit()

      assert html =~ ~s(phx-mounted)
      assert html =~ "quiz_title"
      assert html =~ "Corrija os campos destacados."
    end

    test "validates on change without persisting", %{conn: conn, scope: scope, quiz: quiz} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      html = lv |> form("#quiz-form", %{"quiz" => %{"title" => "AB"}}) |> render_change()

      assert html =~ "deve ter pelo menos 3 caracteres"
      assert Quizzes.get_quiz!(scope, quiz.id).title == "Geografia"
    end

    test "guards the submit button against double submission", %{conn: conn, quiz: quiz} do
      {:ok, _lv, html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      assert html =~ ~s(phx-disable-with="Salvando...")
    end
  end

  describe "question list" do
    test "shows an empty state with a link to the first question", %{conn: conn, quiz: quiz} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      assert has_element?(lv, "#questions-empty")
      assert render(lv) =~ "Este quiz ainda não tem perguntas"
      assert has_element?(lv, "#first-question-button")
      refute has_element?(lv, "#questions")
    end

    test "lists the questions by position with the correct option", %{
      conn: conn,
      scope: scope,
      quiz: quiz
    } do
      first = question_fixture(scope, quiz, %{text: "Primeira pergunta"})
      second = question_fixture(scope, quiz, %{text: "Segunda pergunta"})

      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      refute has_element?(lv, "#questions-empty")
      assert has_element?(lv, "#question-#{first.id}")
      assert has_element?(lv, "#question-#{second.id}")

      assert lv |> element("#question-#{first.id}") |> render() =~ "Primeira pergunta"
      assert lv |> element("#question-#{first.id}") |> render() =~ "Correta: A. Brasília"
      assert positions_in_order(lv, [first, second])
    end

    test "truncates a very long question text", %{conn: conn, scope: scope, quiz: quiz} do
      long = String.duplicate("a", 200)
      question = question_fixture(scope, quiz, %{text: long})

      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      item = lv |> element("#question-#{question.id}") |> render()

      assert item =~ "…"
      refute item =~ long
    end
  end

  describe "adding a question" do
    test "opens the modal with four blank options", %{conn: conn, quiz: quiz} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      lv |> element("#add-question-button") |> render_click()

      assert_patch(lv, ~p"/quizzes/#{quiz}/questions/new")
      assert has_element?(lv, "#question-modal")
      assert has_element?(lv, "#question-form")

      for index <- 0..3 do
        assert has_element?(lv, "#question_answer_options_#{index}_text")
      end

      for position <- 1..4 do
        assert has_element?(lv, "#question-correct-#{position}")
        refute has_element?(lv, "#question-correct-#{position}[checked]")
      end
    end

    test "creates the question, closes the modal and confirms it", %{
      conn: conn,
      scope: scope,
      quiz: quiz
    } do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/questions/new")

      html =
        lv
        |> form("#question-form", question: question_params())
        |> render_submit()

      assert_patch(lv, ~p"/quizzes/#{quiz}/edit")
      refute has_element?(lv, "#question-form")
      assert html =~ "Pergunta adicionada" or render(lv) =~ "Pergunta adicionada"

      assert [question] = Quizzes.get_quiz_with_questions!(scope, quiz.id).questions
      assert question.text == "Qual é a capital do Brasil?"
      assert question.position == 1
      assert Enum.find(question.answer_options, & &1.is_correct).text == "Brasília"

      assert has_element?(lv, "#question-#{question.id}")
      assert lv |> element("#question-#{question.id}") |> render() =~ "1"
    end

    test "new questions go to the end of the list", %{conn: conn, scope: scope, quiz: quiz} do
      question_fixture(scope, quiz, %{text: "Primeira"})
      question_fixture(scope, quiz, %{text: "Segunda"})

      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/questions/new")

      lv |> form("#question-form", question: question_params()) |> render_submit()

      assert_patch(lv, ~p"/quizzes/#{quiz}/edit")

      created = scope |> Quizzes.get_quiz_with_questions!(quiz.id) |> Map.fetch!(:questions)

      assert Enum.map(created, & &1.position) == [1, 2, 3]
      assert List.last(created).text == "Qual é a capital do Brasil?"
    end

    test "refuses to save without a correct option", %{conn: conn, scope: scope, quiz: quiz} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/questions/new")

      params = question_params() |> Map.delete("correct_position")

      html = lv |> form("#question-form", question: params) |> render_submit()

      assert html =~ "marque a alternativa correta"
      assert has_element?(lv, "#question-set-errors")
      assert has_element?(lv, "#question-form")
      assert html =~ "Qual é a capital do Brasil?"
      assert html =~ ~s(value="Brasília")
      assert html =~ ~s(value="Salvador")
      assert Quizzes.get_quiz_with_questions!(scope, quiz.id).questions == []
    end

    test "refuses to save with a blank option", %{conn: conn, scope: scope, quiz: quiz} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/questions/new")

      params = put_option_text(question_params(), "2", "")

      html = lv |> form("#question-form", question: params) |> render_submit()

      assert html =~ "não pode ficar em branco"
      assert has_element?(lv, "#question-form")
      assert Quizzes.get_quiz_with_questions!(scope, quiz.id).questions == []
    end

    test "refuses to save with repeated option texts", %{conn: conn, scope: scope, quiz: quiz} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/questions/new")

      params =
        question_params()
        |> put_option_text("0", "Brasil")
        |> put_option_text("3", "brasil")

      html = lv |> form("#question-form", question: params) |> render_submit()

      assert html =~ "as alternativas não podem ter textos repetidos"
      assert has_element?(lv, "#question-set-errors")
      assert Quizzes.get_quiz_with_questions!(scope, quiz.id).questions == []
    end

    test "refuses a question text that is too short", %{conn: conn, scope: scope, quiz: quiz} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/questions/new")

      params = Map.put(question_params(), "text", "AB")

      html = lv |> form("#question-form", question: params) |> render_submit()

      assert html =~ "deve ter pelo menos 3 caracteres"
      assert has_element?(lv, "#question-form")
      assert has_element?(lv, "#question-correct-1[checked]")
      assert html =~ ~s(value="Brasília")
      assert Quizzes.get_quiz_with_questions!(scope, quiz.id).questions == []
    end

    test "refuses a question text that is too long", %{conn: conn, scope: scope, quiz: quiz} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/questions/new")

      params = Map.put(question_params(), "text", String.duplicate("a", 501))

      html = lv |> form("#question-form", question: params) |> render_submit()

      assert html =~ "deve ter no máximo 500 caracteres"
      assert has_element?(lv, "#question-form")
      assert Quizzes.get_quiz_with_questions!(scope, quiz.id).questions == []
    end

    test "moves focus to the first field with an error", %{conn: conn, quiz: quiz} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/questions/new")

      params = Map.put(question_params(), "text", "AB")

      html = lv |> form("#question-form", question: params) |> render_submit()

      assert html =~ "Corrija os campos destacados."
      assert html =~ "question_text"
    end

    test "validates on change without persisting", %{conn: conn, scope: scope, quiz: quiz} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/questions/new")

      params = Map.put(question_params(), "text", "AB")

      html = lv |> form("#question-form", question: params) |> render_change()

      assert html =~ "deve ter pelo menos 3 caracteres"
      assert has_element?(lv, "#question-form")
      assert Quizzes.get_quiz_with_questions!(scope, quiz.id).questions == []
    end
  end

  describe "editing a question" do
    setup %{scope: scope, quiz: quiz} do
      %{question: question_fixture(scope, quiz, %{text: "Qual é a capital do Brasil?"})}
    end

    test "opens the modal with the current values", %{conn: conn, quiz: quiz, question: question} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      lv |> element("#question-#{question.id} a", "Editar") |> render_click()

      assert_patch(lv, ~p"/quizzes/#{quiz}/questions/#{question}/edit")
      assert has_element?(lv, "#question-form")

      html = render(lv)
      assert html =~ "Qual é a capital do Brasil?"
      assert html =~ "Brasília"
      assert has_element?(lv, "#question-correct-1[checked]")
      refute has_element?(lv, "#question-correct-2[checked]")
    end

    test "saves the new text and the new correct option", %{
      conn: conn,
      scope: scope,
      quiz: quiz,
      question: question
    } do
      other = question_fixture(scope, quiz, %{text: "Outra pergunta"})
      option_ids = Enum.map(question.answer_options, & &1.id)

      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/questions/#{question}/edit")

      params = %{"text" => "Qual é a capital federal?", "correct_position" => "4"}

      lv |> form("#question-form", question: params) |> render_submit()

      assert_patch(lv, ~p"/quizzes/#{quiz}/edit")
      refute has_element?(lv, "#question-form")
      assert render(lv) =~ "Pergunta atualizada"

      updated = Quizzes.get_question!(scope, quiz, question.id)

      assert updated.text == "Qual é a capital federal?"
      assert updated.position == question.position
      assert Enum.find(updated.answer_options, & &1.is_correct).position == 4
      assert Enum.map(updated.answer_options, & &1.id) == option_ids

      assert lv |> element("#question-#{question.id}") |> render() =~ "Qual é a capital federal?"
      assert lv |> element("#question-#{question.id}") |> render() =~ "Correta: D. Salvador"
      assert Quizzes.get_question!(scope, quiz, other.id).position == other.position
    end

    test "keeps the modal open on invalid data", %{
      conn: conn,
      scope: scope,
      quiz: quiz,
      question: question
    } do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/questions/#{question}/edit")

      params = %{"text" => "AB"}

      html = lv |> form("#question-form", question: params) |> render_submit()

      assert html =~ "deve ter pelo menos 3 caracteres"
      assert has_element?(lv, "#question-form")
      assert Quizzes.get_question!(scope, quiz, question.id).text == question.text
    end

    test "cancelling closes the modal and keeps the question", %{
      conn: conn,
      scope: scope,
      quiz: quiz,
      question: question
    } do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/questions/#{question}/edit")

      lv |> form("#question-form", question: %{"text" => "Rascunho perdido"}) |> render_change()

      lv |> element("#question-form a", "Cancelar") |> render_click()

      assert_patch(lv, ~p"/quizzes/#{quiz}/edit")
      refute has_element?(lv, "#question-form")

      kept = Quizzes.get_question!(scope, quiz, question.id)

      assert kept.text == question.text
      assert Enum.find(kept.answer_options, & &1.is_correct).position == 1
    end

    test "answers 404 for a question of another user", %{conn: conn} do
      foreign_scope = user_scope_fixture()
      foreign_quiz = quiz_fixture(foreign_scope)
      foreign_question = question_fixture(foreign_scope, foreign_quiz)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/quizzes/#{foreign_quiz}/questions/#{foreign_question}/edit")
      end
    end

    test "answers 404 for a question of another quiz", %{conn: conn, scope: scope, quiz: quiz} do
      other_quiz = quiz_fixture(scope, %{title: "Outro quiz"})
      other_question = question_fixture(scope, other_quiz)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/quizzes/#{quiz}/questions/#{other_question}/edit")
      end
    end
  end

  describe "question limit" do
    setup %{scope: scope, quiz: quiz} do
      fill_quiz(scope, quiz, Quizzes.max_questions())

      :ok
    end

    test "disables the add button and explains why", %{conn: conn, quiz: quiz} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      assert has_element?(lv, "#add-question-button[disabled]")
      assert render(lv) =~ "Limite de 50 perguntas atingido"
    end

    test "sends a direct visit back to the editor", %{conn: conn, quiz: quiz} do
      result = live(conn, ~p"/quizzes/#{quiz}/questions/new")

      assert {:error, {:live_redirect, %{to: path}}} = result
      assert path == ~p"/quizzes/#{quiz}/edit"

      {:ok, lv, html} = follow_redirect(result, conn)

      refute has_element?(lv, "#question-form")
      assert html =~ "Este quiz já atingiu o limite de 50 perguntas"
    end
  end

  describe "question limit reached while the modal is open" do
    test "shows the flash without breaking the screen", %{conn: conn, scope: scope, quiz: quiz} do
      fill_quiz(scope, quiz, Quizzes.max_questions() - 1)

      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/questions/new")

      # Somebody else fills the last slot while this modal is open.
      fill_quiz(scope, quiz, 1)

      lv |> form("#question-form", question: question_params()) |> render_submit()

      assert_patch(lv, ~p"/quizzes/#{quiz}/edit")
      assert render(lv) =~ "Este quiz já atingiu o limite de 50 perguntas"
      refute has_element?(lv, "#question-form")

      assert length(Quizzes.get_quiz_with_questions!(scope, quiz.id).questions) ==
               Quizzes.max_questions()
    end
  end

  describe "reordering questions" do
    setup %{scope: scope, quiz: quiz} do
      %{
        first: question_fixture(scope, quiz, %{text: "Pergunta A"}),
        second: question_fixture(scope, quiz, %{text: "Pergunta B"}),
        third: question_fixture(scope, quiz, %{text: "Pergunta C"})
      }
    end

    test "moving a question up reorders the list and the database", %{
      conn: conn,
      scope: scope,
      quiz: quiz,
      first: first,
      second: second,
      third: third
    } do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      lv |> element("#move-question-up-#{second.id}") |> render_click()

      assert positions_in_order(lv, [second, first, third])
      assert displayed_positions(lv, [second, first, third]) == ["1", "2", "3"]
      assert stored_order(scope, quiz) == [second.id, first.id, third.id]
    end

    test "moving a question down reorders the list and the database", %{
      conn: conn,
      scope: scope,
      quiz: quiz,
      first: first,
      second: second,
      third: third
    } do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      lv |> element("#move-question-down-#{first.id}") |> render_click()

      assert positions_in_order(lv, [second, first, third])
      assert displayed_positions(lv, [second, first, third]) == ["1", "2", "3"]
      assert stored_order(scope, quiz) == [second.id, first.id, third.id]
    end

    test "the arrows at the edges are disabled", %{
      conn: conn,
      quiz: quiz,
      first: first,
      second: second,
      third: third
    } do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      assert has_element?(lv, "#move-question-up-#{first.id}[disabled]")
      assert has_element?(lv, "#move-question-down-#{third.id}[disabled]")

      refute has_element?(lv, "#move-question-down-#{first.id}[disabled]")
      refute has_element?(lv, "#move-question-up-#{second.id}[disabled]")
      refute has_element?(lv, "#move-question-down-#{second.id}[disabled]")
      refute has_element?(lv, "#move-question-up-#{third.id}[disabled]")
    end

    test "the arrows describe what they do", %{conn: conn, quiz: quiz, second: second} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      assert has_element?(
               lv,
               ~s{#move-question-up-#{second.id}[aria-label="Mover pergunta 2 para cima"]}
             )

      assert has_element?(
               lv,
               ~s{#move-question-down-#{second.id}[aria-label="Mover pergunta 2 para baixo"]}
             )
    end

    test "the new order survives a reload", %{
      conn: conn,
      quiz: quiz,
      first: first,
      second: second,
      third: third
    } do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      lv |> element("#move-question-up-#{third.id}") |> render_click()

      {:ok, reloaded, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      assert positions_in_order(reloaded, [first, third, second])
      assert displayed_positions(reloaded, [first, third, second]) == ["1", "2", "3"]
    end

    test "several moves keep the numbering dense", %{
      conn: conn,
      scope: scope,
      quiz: quiz,
      first: first,
      second: second,
      third: third
    } do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      # A B C -> B A C -> B C A -> C B A
      lv |> element("#move-question-down-#{first.id}") |> render_click()
      lv |> element("#move-question-down-#{first.id}") |> render_click()
      lv |> element("#move-question-up-#{third.id}") |> render_click()

      assert positions_in_order(lv, [third, second, first])
      assert displayed_positions(lv, [third, second, first]) == ["1", "2", "3"]
      assert stored_order(scope, quiz) == [third.id, second.id, first.id]
    end

    @tag :capture_log
    test "refuses a forged move of a question of another user", %{conn: conn, quiz: quiz} do
      foreign_scope = user_scope_fixture()
      foreign = question_fixture(foreign_scope, quiz_fixture(foreign_scope))

      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      # The scoped lookup raises inside the LiveView process, which takes the
      # process down instead of touching somebody else's question.
      Process.flag(:trap_exit, true)

      assert {{%Ecto.NoResultsError{}, _stacktrace}, _call} =
               catch_exit(render_click(lv, "move_question_up", %{"id" => foreign.id}))

      assert LiveQuiz.Repo.get(LiveQuiz.Quizzes.Question, foreign.id).position == 1
    end
  end

  describe "deleting a question" do
    setup %{scope: scope, quiz: quiz} do
      %{
        first: question_fixture(scope, quiz, %{text: "Pergunta A"}),
        second: question_fixture(scope, quiz, %{text: "Pergunta B"}),
        third: question_fixture(scope, quiz, %{text: "Pergunta C"})
      }
    end

    test "asks for confirmation showing the question", %{
      conn: conn,
      quiz: quiz,
      second: second
    } do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      html = lv |> element("#delete-question-#{second.id}") |> render_click()

      assert has_element?(lv, "#delete-question")
      assert html =~ "Excluir esta pergunta?"
      assert html =~ "Pergunta B"
      assert html =~ "As 4 alternativas também serão removidas."
    end

    test "confirming deletes it, renumbers the list and says so", %{
      conn: conn,
      scope: scope,
      quiz: quiz,
      first: first,
      second: second,
      third: third
    } do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      lv |> element("#delete-question-#{second.id}") |> render_click()
      html = lv |> element("#delete-question button", "Excluir pergunta") |> render_click()

      assert html =~ "Pergunta excluída"
      refute has_element?(lv, "#delete-question")
      refute has_element?(lv, "#question-#{second.id}")

      assert stored_order(scope, quiz) == [first.id, third.id]
      assert displayed_positions(lv, [first, third]) == ["1", "2"]
      refute LiveQuiz.Repo.get(LiveQuiz.Quizzes.Question, second.id)
    end

    test "cancelling keeps the question", %{conn: conn, scope: scope, quiz: quiz, second: second} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      lv |> element("#delete-question-#{second.id}") |> render_click()
      html = lv |> element("#delete-question button", "Cancelar") |> render_click()

      refute has_element?(lv, "#delete-question")
      refute html =~ "Excluir esta pergunta?"
      assert has_element?(lv, "#question-#{second.id}")
      assert length(stored_order(scope, quiz)) == 3
    end

    @tag :capture_log
    test "refuses a forged delete of a question of another user", %{conn: conn, quiz: quiz} do
      foreign_scope = user_scope_fixture()
      foreign = question_fixture(foreign_scope, quiz_fixture(foreign_scope))

      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      Process.flag(:trap_exit, true)

      assert {{%Ecto.NoResultsError{}, _stacktrace}, _call} =
               catch_exit(render_click(lv, "delete_question", %{"id" => foreign.id}))

      assert LiveQuiz.Repo.get(LiveQuiz.Quizzes.Question, foreign.id)
    end
  end

  describe "deleting the last question" do
    test "brings the empty state back", %{conn: conn, scope: scope, quiz: quiz} do
      question = question_fixture(scope, quiz, %{text: "Única pergunta"})

      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      lv |> element("#delete-question-#{question.id}") |> render_click()
      lv |> element("#delete-question button", "Excluir pergunta") |> render_click()

      assert has_element?(lv, "#questions-empty")
      assert has_element?(lv, "#first-question-button")
      refute has_element?(lv, "#questions")
      assert stored_order(scope, quiz) == []
    end
  end

  describe "deleting a question of a full quiz" do
    test "frees the add button again", %{conn: conn, scope: scope, quiz: quiz} do
      fill_quiz(scope, quiz, Quizzes.max_questions())
      [target | _rest] = Quizzes.get_quiz_with_questions!(scope, quiz.id).questions

      {:ok, lv, _html} = live(conn, ~p"/quizzes/#{quiz}/edit")

      assert has_element?(lv, "#add-question-button[disabled]")

      lv |> element("#delete-question-#{target.id}") |> render_click()
      lv |> element("#delete-question button", "Excluir pergunta") |> render_click()

      refute has_element?(lv, "#add-question-button[disabled]")
      refute has_element?(lv, "#question-limit-hint")
      assert length(stored_order(scope, quiz)) == Quizzes.max_questions() - 1
    end
  end

  defp question_params do
    %{
      "text" => "Qual é a capital do Brasil?",
      "correct_position" => "1",
      "answer_options" => %{
        "0" => %{"text" => "Brasília"},
        "1" => %{"text" => "Rio de Janeiro"},
        "2" => %{"text" => "São Paulo"},
        "3" => %{"text" => "Salvador"}
      }
    }
  end

  defp put_option_text(params, index, text) do
    update_in(params, ["answer_options", index], &Map.put(&1, "text", text))
  end

  defp positions_in_order(lv, questions) do
    html = render(lv)

    questions
    |> Enum.map(&:binary.match(html, ~s(id="question-#{&1.id}")))
    |> Enum.map(fn {start, _length} -> start end)
    |> then(&(&1 == Enum.sort(&1)))
  end

  defp stored_order(scope, quiz) do
    scope
    |> Quizzes.get_quiz_with_questions!(quiz.id)
    |> Map.fetch!(:questions)
    |> Enum.map(& &1.id)
  end

  defp displayed_positions(lv, questions) do
    Enum.map(questions, fn question ->
      lv
      |> element("#question-#{question.id} span.badge")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()
    end)
  end

  defp fill_quiz(scope, quiz, count) do
    existing = length(Quizzes.get_quiz_with_questions!(scope, quiz.id).questions)

    for index <- (existing + 1)..(existing + count) do
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
end
