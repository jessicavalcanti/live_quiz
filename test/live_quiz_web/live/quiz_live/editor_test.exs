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
      assert html =~ "1 pergunta(s)"
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
end
