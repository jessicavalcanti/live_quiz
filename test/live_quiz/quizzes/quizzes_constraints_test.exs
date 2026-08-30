defmodule LiveQuiz.Quizzes.QuizzesConstraintsTest do
  @moduledoc """
  Exercises the guarantees that live in the database, not in the changesets.

  The `quiz_id`/`position` and `question_id`/`position` constraints are
  `DEFERRABLE INITIALLY DEFERRED`, so inside the test sandbox — itself a single
  open transaction — they would never be verified. `SET CONSTRAINTS ALL
  IMMEDIATE` forces the check at the point the tests care about.
  """

  use LiveQuiz.DataCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.QuizzesFixtures

  alias LiveQuiz.Quizzes.AnswerOption
  alias LiveQuiz.Quizzes.Question
  alias LiveQuiz.Quizzes.Quiz

  setup do
    scope = user_scope_fixture()
    %{scope: scope, quiz: quiz_fixture(scope)}
  end

  defp check_constraints_now! do
    Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
  end

  describe "answer option uniqueness" do
    test "rejects a second correct option for the same question", %{scope: scope, quiz: quiz} do
      options = [
        %{text: "Brasília", position: 1, is_correct: true},
        %{text: "Recife", position: 2, is_correct: false}
      ]

      question = question_fixture(scope, quiz, %{answer_options: options})

      assert {:error, changeset} =
               %AnswerOption{question_id: question.id}
               |> AnswerOption.changeset(%{text: "Belém", position: 3, is_correct: true})
               |> Repo.insert()

      assert "já existe uma alternativa correta" in errors_on(changeset).question_id
    end

    test "accepts many incorrect options for the same question", %{scope: scope, quiz: quiz} do
      question = question_fixture(scope, quiz)

      assert Repo.aggregate(
               from(o in AnswerOption, where: o.question_id == ^question.id),
               :count
             ) == 4
    end

    test "rejects two options sharing a position in the same question", %{
      scope: scope,
      quiz: quiz
    } do
      question = question_fixture(scope, quiz)

      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          Repo.insert!(%AnswerOption{
            question_id: question.id,
            text: "Repetida",
            position: 4,
            is_correct: false,
            inserted_at: DateTime.utc_now(:second),
            updated_at: DateTime.utc_now(:second)
          })

          check_constraints_now!()
        end)
      end
    end
  end

  describe "question position uniqueness" do
    test "rejects two questions in the same position at commit time", %{
      scope: scope,
      quiz: quiz
    } do
      question_fixture(scope, quiz, %{position: 1})

      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          question_fixture(scope, quiz, %{position: 1})
          check_constraints_now!()
        end)
      end
    end

    test "allows swapping two positions inside a single transaction", %{
      scope: scope,
      quiz: quiz
    } do
      first = question_fixture(scope, quiz, %{position: 1})
      second = question_fixture(scope, quiz, %{position: 2})

      assert {:ok, :swapped} =
               Repo.transaction(fn ->
                 Repo.update_all(from(q in Question, where: q.id == ^first.id),
                   set: [position: 2]
                 )

                 Repo.update_all(from(q in Question, where: q.id == ^second.id),
                   set: [position: 1]
                 )

                 check_constraints_now!()
                 :swapped
               end)

      assert Repo.get!(Question, first.id).position == 2
      assert Repo.get!(Question, second.id).position == 1
    end
  end

  describe "cascading deletes" do
    test "deleting a quiz removes its questions and answer options", %{
      scope: scope,
      quiz: quiz
    } do
      first = question_fixture(scope, quiz)
      second = question_fixture(scope, quiz)

      assert questions_of(quiz) == 2
      assert options_of([first, second]) == 8

      Repo.delete!(quiz)

      assert questions_of(quiz) == 0
      assert options_of([first, second]) == 0
    end

    test "deleting the owner removes the quiz", %{scope: scope, quiz: quiz} do
      Repo.delete!(scope.user)

      refute Repo.get(Quiz, quiz.id)
    end
  end

  describe "foreign keys" do
    test "rejects a question pointing at a quiz that does not exist" do
      assert_raise Ecto.ConstraintError, fn ->
        %Question{quiz_id: 0}
        |> Question.changeset(%{
          text: "Pergunta órfã",
          position: 1,
          answer_options: valid_answer_options_attributes()
        })
        |> Repo.insert!()
      end
    end
  end

  describe "check constraints" do
    test "rejects a title the changeset would also reject", %{scope: scope} do
      assert_raise Postgrex.Error, fn ->
        Repo.insert_all("quizzes", [
          [
            owner_id: scope.user.id,
            title: "AB",
            description: nil,
            inserted_at: DateTime.utc_now(:second),
            updated_at: DateTime.utc_now(:second)
          ]
        ])
      end
    end
  end

  defp questions_of(%Quiz{} = quiz) do
    Repo.aggregate(from(q in Question, where: q.quiz_id == ^quiz.id), :count)
  end

  defp options_of(questions) do
    ids = Enum.map(questions, & &1.id)
    Repo.aggregate(from(o in AnswerOption, where: o.question_id in ^ids), :count)
  end
end
