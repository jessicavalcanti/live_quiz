defmodule LiveQuizWeb.QuizLive.IndexTest do
  use LiveQuizWeb.ConnCase, async: true

  import Ecto.Query
  import LiveQuiz.AccountsFixtures
  import LiveQuiz.QuizzesFixtures
  import Phoenix.LiveViewTest

  alias LiveQuiz.Accounts.Scope

  describe "route protection" do
    test "redirects a visitor to the log in page", %{conn: conn} do
      assert {:error, {:redirect, %{to: path, flash: flash}}} = live(conn, ~p"/quizzes")

      assert path == ~p"/users/log-in"
      assert flash["error"] == "Você precisa entrar para acessar esta página."
    end

    test "stores the requested path so the user comes back after logging in", %{conn: conn} do
      conn = get(conn, ~p"/quizzes")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert get_session(conn, :user_return_to) == ~p"/quizzes"
    end
  end

  describe "authenticated header" do
    setup :register_and_log_in_user

    test "shows the user name and the account links", %{conn: conn, user: user} do
      {:ok, lv, html} = live(conn, ~p"/quizzes")

      assert html =~ user.name
      assert lv |> element(~s{a[href="/users/settings"]}, "Minha conta") |> has_element?()
      assert lv |> element(~s{a[href="/users/log-out"]}, "Sair") |> has_element?()
    end

    test "hides the confirmation notice for a confirmed user", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/quizzes")

      refute html =~ "Confirme seu e-mail"
    end
  end

  describe "unconfirmed e-mail notice" do
    setup %{conn: conn} do
      user = unconfirmed_user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "warns without blocking navigation", %{conn: conn, user: user} do
      {:ok, lv, html} = live(conn, ~p"/quizzes")

      assert html =~ "Confirme seu e-mail"
      assert html =~ user.email

      assert html =~ "Meus quizzes"
      assert lv |> element(~s{a[href="/users/settings"]}, "Minha conta") |> has_element?()
    end
  end

  describe "listing" do
    setup :register_and_log_in_user

    setup %{user: user} do
      %{scope: Scope.for_user(user)}
    end

    test "renders the quizzes of the current user", %{conn: conn, scope: scope} do
      quiz_fixture(scope, %{title: "Geografia", description: "Capitais do mundo"})
      quiz_fixture(scope, %{title: "História"})
      quiz_fixture(scope, %{title: "Biologia"})

      {:ok, _lv, html} = live(conn, ~p"/quizzes")

      assert html =~ "Geografia"
      assert html =~ "Capitais do mundo"
      assert html =~ "História"
      assert html =~ "Biologia"
    end

    test "does not render quizzes of another user", %{conn: conn, scope: scope} do
      quiz_fixture(scope, %{title: "Meu quiz"})
      quiz_fixture(user_scope_fixture(), %{title: "Quiz do Bruno"})

      {:ok, _lv, html} = live(conn, ~p"/quizzes")

      assert html =~ "Meu quiz"
      refute html =~ "Quiz do Bruno"
    end

    test "shows the question count and the playable indicator", %{conn: conn, scope: scope} do
      empty = quiz_fixture(scope, %{title: "Sem perguntas"})
      filled = quiz_fixture(scope, %{title: "Com perguntas"})
      for _ <- 1..5, do: question_fixture(scope, filled)

      {:ok, lv, _html} = live(conn, ~p"/quizzes")

      assert lv |> element("#quiz-#{filled.id}") |> render() =~ "5 perguntas"
      assert lv |> element("#quiz-#{filled.id}") |> render() =~ "Pronto para jogar"

      assert lv |> element("#quiz-#{empty.id}") |> render() =~ "Nenhuma pergunta"
      assert lv |> element("#quiz-#{empty.id}") |> render() =~ "Incompleto"
    end

    test "says 1 pergunta in the singular", %{conn: conn, scope: scope} do
      quiz = quiz_fixture(scope)
      question_fixture(scope, quiz)

      {:ok, lv, _html} = live(conn, ~p"/quizzes")

      assert lv |> element("#quiz-#{quiz.id}") |> render() =~ "1 pergunta"
    end

    test "shows a dash for a quiz without description", %{conn: conn, scope: scope} do
      quiz = quiz_fixture(scope, %{description: nil})

      {:ok, lv, _html} = live(conn, ~p"/quizzes")

      assert lv |> element("#quiz-#{quiz.id}") |> render() =~ "—"
    end

    test "shows a dash for a description stored as an empty string", %{conn: conn, scope: scope} do
      # The changeset normalizes "" to nil, but a row written by other means can
      # still carry an empty string.
      quiz = quiz_fixture(scope)

      LiveQuiz.Repo.update_all(
        from(q in LiveQuiz.Quizzes.Quiz, where: q.id == ^quiz.id),
        set: [description: ""]
      )

      {:ok, lv, _html} = live(conn, ~p"/quizzes")

      assert lv |> element("#quiz-#{quiz.id}") |> render() =~ "—"
    end

    test "shows the creation date in São Paulo time", %{conn: conn, scope: scope} do
      quiz = quiz_fixture(scope)

      LiveQuiz.Repo.update_all(
        from(q in LiveQuiz.Quizzes.Quiz, where: q.id == ^quiz.id),
        set: [inserted_at: ~U[2026-08-30 02:30:00Z]]
      )

      {:ok, lv, _html} = live(conn, ~p"/quizzes")

      assert lv |> element("#quiz-#{quiz.id}") |> render() =~ "29/08/2026"
    end
  end

  describe "empty states" do
    setup :register_and_log_in_user

    setup %{user: user} do
      %{scope: Scope.for_user(user)}
    end

    test "invites the user to create the first quiz", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/quizzes")

      assert html =~ "Você ainda não criou nenhum quiz."
      assert html =~ "Criar quiz"
    end

    test "reports a search with no results and offers to clear it", %{conn: conn, scope: scope} do
      quiz_fixture(scope, %{title: "Geografia"})

      {:ok, lv, _html} = live(conn, ~p"/quizzes")

      html = lv |> form("form[role=search]", %{"search" => "xyz"}) |> render_change()

      assert html =~ "Nenhum quiz encontrado para &quot;xyz&quot;."
      assert lv |> element("button", "Limpar busca") |> has_element?()
    end
  end

  describe "search" do
    setup :register_and_log_in_user

    setup %{user: user} do
      scope = Scope.for_user(user)
      quiz_fixture(scope, %{title: "Geografia"})
      quiz_fixture(scope, %{title: "História"})

      %{scope: scope}
    end

    test "filters the list and puts the term in the URL", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes")

      html = lv |> form("form[role=search]", %{"search" => "geo"}) |> render_change()

      assert_patch(lv, ~p"/quizzes?search=geo")
      assert html =~ "Geografia"
      refute html =~ "História"
    end

    test "is case-insensitive", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes")

      html = lv |> form("form[role=search]", %{"search" => "GEOGRAFIA"}) |> render_change()

      assert html =~ "Geografia"
      refute html =~ "História"
    end

    test "clearing the search restores the full list", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes?search=geo")

      refute render(lv) =~ "História"

      html = lv |> element("button", "Limpar busca") |> render_click()

      assert_patch(lv, ~p"/quizzes")
      assert html =~ "Geografia"
      assert html =~ "História"
    end

    test "a blank term does not filter anything", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes")

      html = lv |> form("form[role=search]", %{"search" => "   "}) |> render_change()

      assert_patch(lv, ~p"/quizzes")
      assert html =~ "Geografia"
      assert html =~ "História"
    end

    test "renders the state of a shared URL", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/quizzes?search=geo")

      assert html =~ "Geografia"
      refute html =~ "História"
      assert html =~ ~s(value="geo")
    end
  end

  describe "pagination" do
    setup :register_and_log_in_user

    setup %{user: user} do
      scope = Scope.for_user(user)

      for index <- 1..25 do
        quiz_fixture(scope, %{title: "Quiz #{String.pad_leading("#{index}", 2, "0")}"})
      end

      %{scope: scope}
    end

    test "shows 20 quizzes and the page indicator", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/quizzes")

      assert html =~ "Página 1 de 2"
      assert lv |> element("#quizzes") |> render() |> rows() == 20
    end

    test "navigates to the next page and reflects it in the URL", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes")

      html = lv |> element("a", "Próxima") |> render_click()

      assert_patch(lv, ~p"/quizzes?page=2")
      assert html =~ "Página 2 de 2"
      assert lv |> element("#quizzes") |> render() |> rows() == 5
    end

    test "goes back to the previous page", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes?page=2")

      html = lv |> element("a", "Anterior") |> render_click()

      assert_patch(lv, ~p"/quizzes")
      assert html =~ "Página 1 de 2"
    end

    test "renders the state of a shared page URL", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/quizzes?page=2")

      assert html =~ "Página 2 de 2"
      assert html =~ "Quiz 01"
      refute html =~ "Quiz 25"
    end

    test "keeps the search term while paging", %{conn: conn, scope: scope} do
      for index <- 26..50 do
        quiz_fixture(scope, %{title: "Geo #{String.pad_leading("#{index}", 2, "0")}"})
      end

      {:ok, lv, html} = live(conn, ~p"/quizzes?search=geo")

      assert html =~ "Página 1 de 2"

      lv |> element("a", "Próxima") |> render_click()

      params = lv |> assert_patch() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert params == %{"search" => "geo", "page" => "2"}
      assert render(lv) =~ "Página 2 de 2"
    end

    test "searching from a later page starts over at page 1", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes?page=2")

      lv |> form("form[role=search]", %{"search" => "Quiz 0"}) |> render_change()

      assert_patch(lv, ~p"/quizzes?search=Quiz+0")
      assert render(lv) =~ "Quiz 01"
    end

    test "hides the pagination when everything fits on one page", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/quizzes?search=Quiz 01")

      refute lv |> element(~s{nav[aria-label="Paginação"]}) |> has_element?()
    end

    test "an out-of-range page renders an empty list without crashing", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/quizzes?page=99")

      assert html =~ "Esta página não tem quizzes."
      refute html =~ "Você ainda não criou nenhum quiz."

      lv |> element("a", "Voltar para a primeira página") |> render_click()

      assert_patch(lv, ~p"/quizzes")
      assert render(lv) =~ "Página 1 de 2"
    end

    test "a non-numeric page falls back to the first one", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/quizzes?page=abc")

      assert html =~ "Página 1 de 2"
    end
  end

  defp rows(html) do
    html |> String.split("<tr") |> length() |> Kernel.-(1)
  end
end
