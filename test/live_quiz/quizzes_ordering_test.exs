defmodule LiveQuiz.QuizzesOrderingTest do
  use LiveQuiz.DataCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.QuizzesFixtures

  alias LiveQuiz.Quizzes
  alias LiveQuiz.Quizzes.AnswerOption
  alias LiveQuiz.Quizzes.Question

  setup do
    scope = user_scope_fixture()
    other_scope = user_scope_fixture()

    %{scope: scope, other_scope: other_scope, quiz: quiz_fixture(scope)}
  end

  defp seed_questions(scope, quiz, labels) do
    for {label, index} <- Enum.with_index(labels, 1) do
      question_fixture(scope, quiz, %{text: "Pergunta #{label}", position: index})
    end
  end

  defp ordering(quiz) do
    Repo.all(
      from q in Question,
        where: q.quiz_id == ^quiz.id,
        order_by: [asc: q.position],
        select: {q.position, q.text}
    )
  end

  defp positions(quiz) do
    Repo.all(from q in Question, where: q.quiz_id == ^quiz.id, select: q.position)
  end

  defp assert_dense_sequence(quiz) do
    found = Enum.sort(positions(quiz))

    assert found == Enum.to_list(1..length(found)//1),
           "posições esperadas 1..#{length(found)}, encontradas #{inspect(found)}"
  end

  describe "delete_question/2" do
    test "renumbers the questions after the deleted one", %{scope: scope, quiz: quiz} do
      [_a, b, _c, _d] = seed_questions(scope, quiz, ~w(A B C D))

      assert {:ok, deleted} = Quizzes.delete_question(scope, b)
      assert deleted.id == b.id

      assert ordering(quiz) == [
               {1, "Pergunta A"},
               {2, "Pergunta C"},
               {3, "Pergunta D"}
             ]

      assert_dense_sequence(quiz)
    end

    test "renumbers everything when the first one goes", %{scope: scope, quiz: quiz} do
      [a, _b, _c] = seed_questions(scope, quiz, ~w(A B C))

      assert {:ok, _deleted} = Quizzes.delete_question(scope, a)

      assert ordering(quiz) == [{1, "Pergunta B"}, {2, "Pergunta C"}]
      assert_dense_sequence(quiz)
    end

    test "leaves the others alone when the last one goes", %{scope: scope, quiz: quiz} do
      [_a, _b, c] = seed_questions(scope, quiz, ~w(A B C))

      assert {:ok, _deleted} = Quizzes.delete_question(scope, c)

      assert ordering(quiz) == [{1, "Pergunta A"}, {2, "Pergunta B"}]
      assert_dense_sequence(quiz)
    end

    test "removes the four answer options along with it", %{scope: scope, quiz: quiz} do
      [a] = seed_questions(scope, quiz, ~w(A))

      assert Repo.aggregate(from(o in AnswerOption, where: o.question_id == ^a.id), :count) == 4

      assert {:ok, _deleted} = Quizzes.delete_question(scope, a)

      assert Repo.aggregate(from(o in AnswerOption, where: o.question_id == ^a.id), :count) == 0
    end

    test "leaves the quiz empty and unplayable when the only question goes", %{
      scope: scope,
      quiz: quiz
    } do
      [a] = seed_questions(scope, quiz, ~w(A))
      assert Quizzes.playable?(Quizzes.get_quiz!(scope, quiz.id))

      assert {:ok, _deleted} = Quizzes.delete_question(scope, a)

      assert positions(quiz) == []
      refute Quizzes.playable?(Quizzes.get_quiz!(scope, quiz.id))
    end

    test "does not touch the questions of another quiz", %{scope: scope, quiz: quiz} do
      other_quiz = quiz_fixture(scope, %{title: "Outro quiz"})
      [a, _b] = seed_questions(scope, quiz, ~w(A B))
      seed_questions(scope, other_quiz, ~w(X Y Z))

      assert {:ok, _deleted} = Quizzes.delete_question(scope, a)

      assert ordering(other_quiz) == [{1, "Pergunta X"}, {2, "Pergunta Y"}, {3, "Pergunta Z"}]
    end

    test "raises for a question of another owner", %{
      scope: scope,
      other_scope: other_scope
    } do
      other_quiz = quiz_fixture(other_scope)
      [foreign] = seed_questions(other_scope, other_quiz, ~w(A))

      assert_raise Ecto.NoResultsError, fn -> Quizzes.delete_question(scope, foreign) end
      assert positions(other_quiz) == [1]
    end
  end

  describe "move_question/3" do
    test "moves a question down", %{scope: scope, quiz: quiz} do
      [a, _b, _c] = seed_questions(scope, quiz, ~w(A B C))

      assert {:ok, moved} = Quizzes.move_question(scope, a, :down)
      assert moved.position == 2

      assert ordering(quiz) == [{1, "Pergunta B"}, {2, "Pergunta A"}, {3, "Pergunta C"}]
      assert_dense_sequence(quiz)
    end

    test "moves a question up", %{scope: scope, quiz: quiz} do
      [_a, _b, c] = seed_questions(scope, quiz, ~w(A B C))

      assert {:ok, moved} = Quizzes.move_question(scope, c, :up)
      assert moved.position == 2

      assert ordering(quiz) == [{1, "Pergunta A"}, {2, "Pergunta C"}, {3, "Pergunta B"}]
      assert_dense_sequence(quiz)
    end

    test "moves inside a longer list without disturbing the rest", %{scope: scope, quiz: quiz} do
      [_a, _b, c, _d, _e] = seed_questions(scope, quiz, ~w(A B C D E))

      assert {:ok, _moved} = Quizzes.move_question(scope, c, :down)

      assert ordering(quiz) == [
               {1, "Pergunta A"},
               {2, "Pergunta B"},
               {3, "Pergunta D"},
               {4, "Pergunta C"},
               {5, "Pergunta E"}
             ]

      assert_dense_sequence(quiz)
    end

    test "is a successful no-op on the first question moving up", %{scope: scope, quiz: quiz} do
      [a, _b] = seed_questions(scope, quiz, ~w(A B))
      before = ordering(quiz)

      assert {:ok, :unchanged} = Quizzes.move_question(scope, a, :up)
      assert ordering(quiz) == before
    end

    test "is a successful no-op on the last question moving down", %{scope: scope, quiz: quiz} do
      [_a, b] = seed_questions(scope, quiz, ~w(A B))
      before = ordering(quiz)

      assert {:ok, :unchanged} = Quizzes.move_question(scope, b, :down)
      assert ordering(quiz) == before
    end

    test "is a no-op for the only question in either direction", %{scope: scope, quiz: quiz} do
      [a] = seed_questions(scope, quiz, ~w(A))

      assert {:ok, :unchanged} = Quizzes.move_question(scope, a, :up)
      assert {:ok, :unchanged} = Quizzes.move_question(scope, a, :down)
      assert ordering(quiz) == [{1, "Pergunta A"}]
    end

    test "survives an immediate constraint check, which is what deferring buys", %{
      scope: scope,
      quiz: quiz
    } do
      [a, _b, _c] = seed_questions(scope, quiz, ~w(A B C))

      # Inside the sandbox the deferred constraint would never be verified, so
      # the swap is only really proven by forcing the check right after it.
      assert {:ok, :checked} =
               Repo.transaction(fn ->
                 {:ok, _moved} = Quizzes.move_question(scope, a, :down)
                 Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
                 :checked
               end)

      assert ordering(quiz) == [{1, "Pergunta B"}, {2, "Pergunta A"}, {3, "Pergunta C"}]
    end

    test "leaves no duplicated position when the surrounding work fails", %{
      scope: scope,
      quiz: quiz
    } do
      [a, _b, _c] = seed_questions(scope, quiz, ~w(A B C))
      before = ordering(quiz)

      assert_raise RuntimeError, fn ->
        Repo.transaction(fn ->
          {:ok, _moved} = Quizzes.move_question(scope, a, :down)
          raise "falha simulada depois da troca"
        end)
      end

      assert ordering(quiz) == before
      assert_dense_sequence(quiz)
    end

    test "does not touch the questions of another quiz", %{scope: scope, quiz: quiz} do
      other_quiz = quiz_fixture(scope, %{title: "Outro quiz"})
      [a, _b] = seed_questions(scope, quiz, ~w(A B))
      seed_questions(scope, other_quiz, ~w(X Y))

      assert {:ok, _moved} = Quizzes.move_question(scope, a, :down)

      assert ordering(other_quiz) == [{1, "Pergunta X"}, {2, "Pergunta Y"}]
    end

    test "raises for a question of another owner", %{scope: scope, other_scope: other_scope} do
      other_quiz = quiz_fixture(other_scope)
      [foreign, _b] = seed_questions(other_scope, other_quiz, ~w(A B))

      assert_raise Ecto.NoResultsError, fn -> Quizzes.move_question(scope, foreign, :down) end
      assert ordering(other_quiz) == [{1, "Pergunta A"}, {2, "Pergunta B"}]
    end
  end

  describe "position invariant" do
    test "holds through a sequence of deletions and moves", %{scope: scope, quiz: quiz} do
      [a, b, c, d, e] = seed_questions(scope, quiz, ~w(A B C D E))

      assert {:ok, _} = Quizzes.delete_question(scope, b)
      assert_dense_sequence(quiz)

      assert {:ok, _} = Quizzes.delete_question(scope, d)
      assert_dense_sequence(quiz)

      # Left with A (1), C (2), E (3).
      assert {:ok, _} = Quizzes.move_question(scope, Repo.reload!(e), :up)
      assert_dense_sequence(quiz)

      assert {:ok, _} = Quizzes.move_question(scope, Repo.reload!(a), :down)
      assert_dense_sequence(quiz)

      assert {:ok, _} = Quizzes.move_question(scope, Repo.reload!(c), :down)
      assert_dense_sequence(quiz)

      assert Enum.map(ordering(quiz), &elem(&1, 1)) |> Enum.sort() ==
               ["Pergunta A", "Pergunta C", "Pergunta E"]
    end

    test "leaves the quiz updated_at alone", %{scope: scope, quiz: quiz} do
      [a, _b] = seed_questions(scope, quiz, ~w(A B))
      before = Repo.reload!(quiz).updated_at

      assert {:ok, _} = Quizzes.move_question(scope, a, :down)
      assert {:ok, _} = Quizzes.delete_question(scope, Repo.reload!(a))

      assert Repo.reload!(quiz).updated_at == before
    end
  end
end
