defmodule LiveQuiz.QuizzesTest do
  use LiveQuiz.DataCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.QuizzesFixtures

  alias LiveQuiz.Quizzes
  alias LiveQuiz.Quizzes.Quiz

  setup do
    %{scope: user_scope_fixture(), other_scope: user_scope_fixture()}
  end

  describe "create_quiz/2" do
    test "persists a quiz owned by the scope user", %{scope: scope} do
      attrs = %{title: "Geografia", description: "Capitais"}

      assert {:ok, %Quiz{} = quiz} = Quizzes.create_quiz(scope, attrs)
      assert quiz.title == "Geografia"
      assert quiz.description == "Capitais"
      assert quiz.owner_id == scope.user.id
      assert quiz.questions_count == 0
    end

    test "ignores an owner_id smuggled in through the attributes", %{
      scope: scope,
      other_scope: other_scope
    } do
      attrs = %{title: "Geografia", owner_id: other_scope.user.id}

      assert {:ok, quiz} = Quizzes.create_quiz(scope, attrs)
      assert quiz.owner_id == scope.user.id
    end

    test "rejects a quiz without a title", %{scope: scope} do
      assert {:error, changeset} = Quizzes.create_quiz(scope, %{description: "Sem título"})
      assert "can't be blank" in errors_on(changeset).title
      assert Quizzes.list_quizzes(scope).total_entries == 0
    end

    test "rejects a title shorter than 3 characters", %{scope: scope} do
      assert {:error, changeset} = Quizzes.create_quiz(scope, %{title: "AB"})
      assert "should be at least 3 character(s)" in errors_on(changeset).title
    end

    test "rejects a title longer than 120 characters", %{scope: scope} do
      attrs = %{title: String.duplicate("a", 121)}

      assert {:error, changeset} = Quizzes.create_quiz(scope, attrs)
      assert "should be at most 120 character(s)" in errors_on(changeset).title
    end

    test "rejects a description longer than 500 characters", %{scope: scope} do
      attrs = %{title: "Geografia", description: String.duplicate("a", 501)}

      assert {:error, changeset} = Quizzes.create_quiz(scope, attrs)
      assert "should be at most 500 character(s)" in errors_on(changeset).description
    end

    test "normalizes an empty description to nil", %{scope: scope} do
      assert {:ok, quiz} = Quizzes.create_quiz(scope, %{title: "Geografia", description: ""})
      assert quiz.description == nil
    end
  end

  describe "list_quizzes/2 scoping" do
    test "returns only the quizzes of the scope user", %{scope: scope, other_scope: other_scope} do
      mine = [quiz_fixture(scope), quiz_fixture(scope)]
      for _ <- 1..3, do: quiz_fixture(other_scope)

      page = Quizzes.list_quizzes(scope)

      assert page.total_entries == 2

      assert Enum.map(page.entries, & &1.id) |> Enum.sort() ==
               Enum.map(mine, & &1.id) |> Enum.sort()
    end

    test "returns an empty page when the user has no quizzes", %{scope: scope} do
      assert %{entries: [], total_entries: 0, total_pages: 0} = Quizzes.list_quizzes(scope)
    end

    test "orders by updated_at descending", %{scope: scope} do
      older = quiz_fixture(scope, %{title: "Mais antigo"})
      newer = quiz_fixture(scope, %{title: "Mais novo"})

      backdate!(older, -3600)

      page = Quizzes.list_quizzes(scope)

      assert Enum.map(page.entries, & &1.id) == [newer.id, older.id]
    end

    test "moves a freshly edited quiz back to the top", %{scope: scope} do
      first = quiz_fixture(scope, %{title: "Primeiro"})
      second = quiz_fixture(scope, %{title: "Segundo"})

      backdate!(first, -3600)
      backdate!(second, -1800)

      {:ok, _updated} = Quizzes.update_quiz(scope, first, %{title: "Reeditado"})

      assert Enum.map(Quizzes.list_quizzes(scope).entries, & &1.id) == [first.id, second.id]
    end

    test "breaks a tie on updated_at with the newest quiz first", %{scope: scope} do
      first = quiz_fixture(scope, %{title: "Primeiro"})
      second = quiz_fixture(scope, %{title: "Segundo"})

      same_moment = DateTime.utc_now(:second)
      backdate_to!(first, same_moment)
      backdate_to!(second, same_moment)

      assert Enum.map(Quizzes.list_quizzes(scope).entries, & &1.id) == [second.id, first.id]
    end
  end

  describe "list_quizzes/2 question count" do
    test "counts the questions of each quiz, including zero", %{scope: scope} do
      empty = quiz_fixture(scope, %{title: "Vazio"})
      filled = quiz_fixture(scope, %{title: "Cheio"})
      for _ <- 1..3, do: question_fixture(scope, filled)

      counts =
        scope
        |> Quizzes.list_quizzes()
        |> Map.fetch!(:entries)
        |> Map.new(&{&1.id, &1.questions_count})

      assert counts[empty.id] == 0
      assert counts[filled.id] == 3
    end

    test "resolves in two queries regardless of how many quizzes there are", %{scope: scope} do
      for index <- 1..10 do
        quiz = quiz_fixture(scope, %{title: "Quiz #{index}"})
        question_fixture(scope, quiz)
      end

      assert count_queries(fn -> Quizzes.list_quizzes(scope) end) == 2

      for index <- 11..20 do
        quiz = quiz_fixture(scope, %{title: "Quiz #{index}"})
        question_fixture(scope, quiz)
      end

      assert count_queries(fn -> Quizzes.list_quizzes(scope, per_page: 100) end) == 2
    end
  end

  describe "list_quizzes/2 pagination" do
    setup %{scope: scope} do
      for index <- 1..25 do
        quiz_fixture(scope, %{title: "Quiz #{String.pad_leading("#{index}", 2, "0")}"})
      end

      :ok
    end

    test "returns the first page by default", %{scope: scope} do
      page = Quizzes.list_quizzes(scope)

      assert length(page.entries) == 20
      assert page.page == 1
      assert page.per_page == 20
      assert page.total_entries == 25
      assert page.total_pages == 2
    end

    test "returns the remainder on the last page", %{scope: scope} do
      page = Quizzes.list_quizzes(scope, page: 2, per_page: 20)

      assert length(page.entries) == 5
      assert page.page == 2
      assert page.total_entries == 25
      assert page.total_pages == 2
    end

    test "returns no entries past the last page", %{scope: scope} do
      page = Quizzes.list_quizzes(scope, page: 99)

      assert page.entries == []
      assert page.total_entries == 25
    end

    test "does not repeat a quiz across pages", %{scope: scope} do
      first = Quizzes.list_quizzes(scope, per_page: 10, page: 1).entries
      second = Quizzes.list_quizzes(scope, per_page: 10, page: 2).entries
      third = Quizzes.list_quizzes(scope, per_page: 10, page: 3).entries

      ids = Enum.map(first ++ second ++ third, & &1.id)

      assert length(ids) == 25
      assert length(Enum.uniq(ids)) == 25
    end

    test "accepts numeric strings", %{scope: scope} do
      page = Quizzes.list_quizzes(scope, page: "2", per_page: "20")

      assert page.page == 2
      assert page.per_page == 20
      assert length(page.entries) == 5
    end

    test "falls back to the defaults on invalid values", %{scope: scope} do
      for bad <- [0, -3, "abc", nil, 1.5, :first] do
        page = Quizzes.list_quizzes(scope, page: bad, per_page: bad)

        assert page.page == 1
        assert page.per_page == 20
      end
    end

    test "falls back to the default when per_page is above the maximum", %{scope: scope} do
      assert Quizzes.list_quizzes(scope, per_page: 101).per_page == 20
      assert Quizzes.list_quizzes(scope, per_page: 100).per_page == 100
    end
  end

  describe "list_quizzes/2 search" do
    setup %{scope: scope} do
      %{
        geography: quiz_fixture(scope, %{title: "Geografia"}),
        history: quiz_fixture(scope, %{title: "História"})
      }
    end

    test "matches part of the title", %{scope: scope, geography: geography} do
      page = Quizzes.list_quizzes(scope, search: "geo")

      assert Enum.map(page.entries, & &1.id) == [geography.id]
      assert page.total_entries == 1
    end

    test "is case-insensitive", %{scope: scope, geography: geography} do
      page = Quizzes.list_quizzes(scope, search: "GEOGRAFIA")

      assert Enum.map(page.entries, & &1.id) == [geography.id]
    end

    test "ignores a blank term", %{scope: scope} do
      assert Quizzes.list_quizzes(scope, search: "   ").total_entries == 2
      assert Quizzes.list_quizzes(scope, search: "").total_entries == 2
      assert Quizzes.list_quizzes(scope, search: nil).total_entries == 2
    end

    test "returns nothing when no title matches", %{scope: scope} do
      assert Quizzes.list_quizzes(scope, search: "biologia").total_entries == 0
    end

    test "treats the ILIKE wildcards as literal characters", %{scope: scope} do
      literal = quiz_fixture(scope, %{title: "100% de acerto"})

      assert Quizzes.list_quizzes(scope, search: "%").total_entries == 1

      assert Enum.map(Quizzes.list_quizzes(scope, search: "0% de").entries, & &1.id) == [
               literal.id
             ]

      assert Quizzes.list_quizzes(scope, search: "_").total_entries == 0
    end

    test "never crosses into another user's quizzes", %{scope: scope, other_scope: other_scope} do
      quiz_fixture(other_scope, %{title: "Geografia do Bruno"})

      assert Quizzes.list_quizzes(scope, search: "geografia").total_entries == 1
    end
  end

  describe "get_quiz!/2" do
    test "returns the quiz with the question count filled in", %{scope: scope} do
      quiz = quiz_fixture(scope)
      for _ <- 1..3, do: question_fixture(scope, quiz)

      assert Quizzes.get_quiz!(scope, quiz.id).questions_count == 3
    end

    test "fills the count with zero for a quiz without questions", %{scope: scope} do
      quiz = quiz_fixture(scope)

      assert Quizzes.get_quiz!(scope, quiz.id).questions_count == 0
    end

    test "accepts the id as a string", %{scope: scope} do
      quiz = quiz_fixture(scope)

      assert Quizzes.get_quiz!(scope, to_string(quiz.id)).id == quiz.id
    end

    test "raises for an id that does not exist", %{scope: scope} do
      assert_raise Ecto.NoResultsError, fn -> Quizzes.get_quiz!(scope, 0) end
    end

    test "raises for a quiz owned by somebody else", %{scope: scope, other_scope: other_scope} do
      quiz = quiz_fixture(other_scope)

      assert_raise Ecto.NoResultsError, fn -> Quizzes.get_quiz!(scope, quiz.id) end
    end
  end

  describe "get_quiz_with_questions!/2" do
    test "preloads questions and options ordered by position", %{scope: scope} do
      quiz = quiz_fixture(scope)
      question_fixture(scope, quiz, %{text: "Segunda pergunta", position: 2})
      question_fixture(scope, quiz, %{text: "Primeira pergunta", position: 1})

      loaded = Quizzes.get_quiz_with_questions!(scope, quiz.id)

      assert Enum.map(loaded.questions, & &1.position) == [1, 2]
      assert Enum.map(loaded.questions, & &1.text) == ["Primeira pergunta", "Segunda pergunta"]

      for question <- loaded.questions do
        assert Enum.map(question.answer_options, & &1.position) == [1, 2, 3, 4]
      end
    end

    test "fills the question count too", %{scope: scope} do
      quiz = quiz_fixture(scope)
      question_fixture(scope, quiz)

      assert Quizzes.get_quiz_with_questions!(scope, quiz.id).questions_count == 1
    end

    test "raises for a quiz owned by somebody else", %{scope: scope, other_scope: other_scope} do
      quiz = quiz_fixture(other_scope)

      assert_raise Ecto.NoResultsError, fn ->
        Quizzes.get_quiz_with_questions!(scope, quiz.id)
      end
    end
  end

  describe "update_quiz/3" do
    test "persists the new title", %{scope: scope} do
      quiz = quiz_fixture(scope, %{title: "Geografia"})

      assert {:ok, updated} = Quizzes.update_quiz(scope, quiz, %{title: "Geografia do Brasil"})
      assert updated.title == "Geografia do Brasil"
      assert Quizzes.get_quiz!(scope, quiz.id).title == "Geografia do Brasil"
    end

    test "bumps updated_at", %{scope: scope} do
      quiz = quiz_fixture(scope)

      {:ok, updated} = Quizzes.update_quiz(scope, quiz, %{title: "Outro título"})

      assert DateTime.compare(updated.updated_at, quiz.updated_at) in [:gt, :eq]
    end

    test "keeps the question count on the returned struct", %{scope: scope} do
      quiz = quiz_fixture(scope)
      question_fixture(scope, quiz)
      loaded = Quizzes.get_quiz!(scope, quiz.id)

      assert {:ok, updated} = Quizzes.update_quiz(scope, loaded, %{title: "Renomeado"})
      assert updated.questions_count == 1
    end

    test "fills the question count when the given quiz does not carry it", %{scope: scope} do
      quiz = quiz_fixture(scope)
      question_fixture(scope, quiz)

      assert {:ok, updated} = Quizzes.update_quiz(scope, quiz, %{title: "Renomeado"})
      assert updated.questions_count == 1
    end

    test "returns an invalid changeset and changes nothing", %{scope: scope} do
      quiz = quiz_fixture(scope, %{title: "Geografia"})

      assert {:error, changeset} = Quizzes.update_quiz(scope, quiz, %{title: "AB"})
      assert "should be at least 3 character(s)" in errors_on(changeset).title
      assert Quizzes.get_quiz!(scope, quiz.id).title == "Geografia"
    end

    test "refuses a quiz that belongs to somebody else", %{scope: scope, other_scope: other} do
      quiz = quiz_fixture(other)

      assert_raise MatchError, fn -> Quizzes.update_quiz(scope, quiz, %{title: "Invadido"}) end
    end
  end

  describe "delete_quiz/2" do
    test "removes the quiz and cascades to questions and options", %{scope: scope} do
      quiz = quiz_fixture(scope)
      first = question_fixture(scope, quiz)
      second = question_fixture(scope, quiz)

      assert {:ok, deleted} = Quizzes.delete_quiz(scope, Quizzes.get_quiz!(scope, quiz.id))
      assert deleted.id == quiz.id

      assert_raise Ecto.NoResultsError, fn -> Quizzes.get_quiz!(scope, quiz.id) end
      assert questions_left([first, second]) == 0
      assert options_left([first, second]) == 0
    end

    test "fills the question count when the given quiz does not carry it", %{scope: scope} do
      quiz = quiz_fixture(scope)
      question_fixture(scope, quiz)

      assert {:ok, deleted} = Quizzes.delete_quiz(scope, quiz)
      assert deleted.questions_count == 1
    end

    test "refuses a quiz that belongs to somebody else", %{scope: scope, other_scope: other} do
      quiz = quiz_fixture(other)

      assert_raise MatchError, fn -> Quizzes.delete_quiz(scope, quiz) end
    end
  end

  describe "change_quiz/2" do
    test "returns a changeset for the given quiz", %{scope: scope} do
      quiz = quiz_fixture(scope)

      assert %Ecto.Changeset{} = changeset = Quizzes.change_quiz(quiz, %{title: "Novo"})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :title) == "Novo"
    end

    test "works without attributes" do
      assert %Ecto.Changeset{} = Quizzes.change_quiz(%Quiz{})
    end
  end

  describe "playable?/1" do
    test "is false for a quiz without questions", %{scope: scope} do
      quiz = quiz_fixture(scope)

      refute Quizzes.playable?(Quizzes.get_quiz!(scope, quiz.id))
    end

    test "becomes true once a question is added", %{scope: scope} do
      quiz = quiz_fixture(scope)
      refute Quizzes.playable?(Quizzes.get_quiz!(scope, quiz.id))

      question_fixture(scope, quiz)

      assert Quizzes.playable?(Quizzes.get_quiz!(scope, quiz.id))
    end

    test "raises for a quiz assembled without the count" do
      assert_raise ArgumentError, fn -> Quizzes.playable?(%Quiz{title: "Solto"}) end
    end
  end

  defp backdate!(%Quiz{} = quiz, seconds) do
    backdate_to!(quiz, DateTime.add(DateTime.utc_now(:second), seconds, :second))
  end

  defp backdate_to!(%Quiz{} = quiz, %DateTime{} = moment) do
    Repo.update_all(from(q in Quiz, where: q.id == ^quiz.id), set: [updated_at: moment])
  end

  defp questions_left(questions) do
    ids = Enum.map(questions, & &1.id)

    Repo.aggregate(from(q in LiveQuiz.Quizzes.Question, where: q.id in ^ids), :count)
  end

  defp options_left(questions) do
    ids = Enum.map(questions, & &1.id)

    Repo.aggregate(
      from(o in LiveQuiz.Quizzes.AnswerOption, where: o.question_id in ^ids),
      :count
    )
  end

  # Counts only the queries issued by this test process, so a concurrent async
  # test cannot inflate the number.
  defp count_queries(fun) do
    parent = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:live_quiz, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == parent, do: send(parent, {ref, :query})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    drain(ref, 0)
  end

  defp drain(ref, count) do
    receive do
      {^ref, :query} -> drain(ref, count + 1)
    after
      0 -> count
    end
  end
end
