defmodule LiveQuiz.QuizzesQuestionsTest do
  use LiveQuiz.DataCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.QuizzesFixtures

  alias LiveQuiz.Quizzes
  alias LiveQuiz.Quizzes.AnswerOption
  alias LiveQuiz.Quizzes.Question

  setup do
    scope = user_scope_fixture()
    other_scope = user_scope_fixture()

    %{
      scope: scope,
      other_scope: other_scope,
      quiz: quiz_fixture(scope),
      other_quiz: quiz_fixture(other_scope)
    }
  end

  defp options(overrides \\ %{}) do
    [
      %{text: "Rio de Janeiro", position: 1, is_correct: false},
      %{text: "Brasília", position: 2, is_correct: true},
      %{text: "São Paulo", position: 3, is_correct: false},
      %{text: "Salvador", position: 4, is_correct: false}
    ]
    |> Enum.map(&Map.merge(&1, Map.get(overrides, &1.position, %{})))
  end

  defp attrs(overrides \\ %{}) do
    Enum.into(overrides, %{text: "Qual é a capital do Brasil?", answer_options: options()})
  end

  defp counts do
    {Repo.aggregate(Question, :count), Repo.aggregate(AnswerOption, :count)}
  end

  describe "create_question/3" do
    test "persists the question and its four options", %{scope: scope, quiz: quiz} do
      assert {:ok, question} = Quizzes.create_question(scope, quiz, attrs())

      assert question.text == "Qual é a capital do Brasil?"
      assert question.quiz_id == quiz.id
      assert question.position == 1

      assert Enum.map(question.answer_options, & &1.position) == [1, 2, 3, 4]

      assert Enum.map(question.answer_options, & &1.text) ==
               ["Rio de Janeiro", "Brasília", "São Paulo", "Salvador"]

      assert Enum.map(question.answer_options, & &1.is_correct) == [false, true, false, false]
    end

    test "accepts string-keyed attributes", %{scope: scope, quiz: quiz} do
      string_attrs = %{
        "text" => "Qual é a capital do Brasil?",
        "answer_options" => [
          %{"text" => "Rio de Janeiro", "position" => 1, "is_correct" => false},
          %{"text" => "Brasília", "position" => 2, "is_correct" => true},
          %{"text" => "São Paulo", "position" => 3, "is_correct" => false},
          %{"text" => "Salvador", "position" => 4, "is_correct" => false}
        ]
      }

      assert {:ok, question} = Quizzes.create_question(scope, quiz, string_attrs)
      assert question.position == 1
    end

    test "increments the position on every new question", %{scope: scope, quiz: quiz} do
      assert {:ok, first} = Quizzes.create_question(scope, quiz, attrs())
      assert {:ok, second} = Quizzes.create_question(scope, quiz, attrs())
      assert {:ok, third} = Quizzes.create_question(scope, quiz, attrs())

      assert Enum.map([first, second, third], & &1.position) == [1, 2, 3]
    end

    test "ignores a position sent by the client", %{scope: scope, quiz: quiz} do
      assert {:ok, question} = Quizzes.create_question(scope, quiz, attrs(%{position: 99}))

      assert question.position == 1
    end

    test "counts positions per quiz, not globally", %{scope: scope, quiz: quiz} do
      another = quiz_fixture(scope, %{title: "Outro quiz"})

      assert {:ok, _first} = Quizzes.create_question(scope, quiz, attrs())
      assert {:ok, elsewhere} = Quizzes.create_question(scope, another, attrs())

      assert elsewhere.position == 1
    end

    test "refuses a quiz that belongs to somebody else", %{scope: scope, other_quiz: other_quiz} do
      assert_raise MatchError, fn -> Quizzes.create_question(scope, other_quiz, attrs()) end
    end
  end

  describe "create_question/3 with invalid data" do
    test "rejects a question with no correct option and persists nothing", %{
      scope: scope,
      quiz: quiz
    } do
      before = counts()
      none_correct = Enum.map(options(), &Map.put(&1, :is_correct, false))

      assert {:error, changeset} =
               Quizzes.create_question(scope, quiz, attrs(%{answer_options: none_correct}))

      assert "marque a alternativa correta" in errors_on(changeset).answer_options
      assert counts() == before
    end

    test "rejects two correct options and persists nothing", %{scope: scope, quiz: quiz} do
      before = counts()
      two_correct = options(%{1 => %{is_correct: true}})

      assert {:error, changeset} =
               Quizzes.create_question(scope, quiz, attrs(%{answer_options: two_correct}))

      assert "marque apenas uma alternativa correta" in errors_on(changeset).answer_options
      assert counts() == before
    end

    test "rejects three options and persists nothing", %{scope: scope, quiz: quiz} do
      before = counts()
      three = Enum.take(options(), 3)

      assert {:error, changeset} =
               Quizzes.create_question(scope, quiz, attrs(%{answer_options: three}))

      assert "a pergunta deve ter exatamente 4 alternativas" in errors_on(changeset).answer_options

      assert counts() == before
    end

    test "rejects five options and persists nothing", %{scope: scope, quiz: quiz} do
      before = counts()
      five = options() ++ [%{text: "Fortaleza", position: 4, is_correct: false}]

      assert {:error, changeset} =
               Quizzes.create_question(scope, quiz, attrs(%{answer_options: five}))

      assert "a pergunta deve ter exatamente 4 alternativas" in errors_on(changeset).answer_options

      assert counts() == before
    end

    test "rejects repeated option texts and persists nothing", %{scope: scope, quiz: quiz} do
      before = counts()
      repeated = options(%{1 => %{text: "Brasil"}, 3 => %{text: "brasil"}})

      assert {:error, changeset} =
               Quizzes.create_question(scope, quiz, attrs(%{answer_options: repeated}))

      assert "as alternativas não podem ter textos repetidos" in errors_on(changeset).answer_options

      assert counts() == before
    end

    test "rejects a blank option and persists nothing", %{scope: scope, quiz: quiz} do
      before = counts()
      blank = options(%{3 => %{text: "  "}})

      assert {:error, changeset} =
               Quizzes.create_question(scope, quiz, attrs(%{answer_options: blank}))

      assert [_, _, %{text: ["can't be blank"]}, _] = errors_on(changeset).answer_options
      assert counts() == before
    end

    test "rejects a question text shorter than 3 characters", %{scope: scope, quiz: quiz} do
      before = counts()

      assert {:error, changeset} = Quizzes.create_question(scope, quiz, attrs(%{text: "Oi"}))
      assert "should be at least 3 character(s)" in errors_on(changeset).text
      assert counts() == before
    end

    test "rejects a question text longer than 500 characters", %{scope: scope, quiz: quiz} do
      before = counts()
      long = String.duplicate("a", 501)

      assert {:error, changeset} = Quizzes.create_question(scope, quiz, attrs(%{text: long}))
      assert "should be at most 500 character(s)" in errors_on(changeset).text
      assert counts() == before
    end

    test "rejects an option text longer than 200 characters", %{scope: scope, quiz: quiz} do
      before = counts()
      long = options(%{2 => %{text: String.duplicate("a", 201)}})

      assert {:error, changeset} =
               Quizzes.create_question(scope, quiz, attrs(%{answer_options: long}))

      assert [_, %{text: ["should be at most 200 character(s)"]}, _, _] =
               errors_on(changeset).answer_options

      assert counts() == before
    end
  end

  describe "create_question/3 limit" do
    test "refuses the 51st question and leaves the quiz with 50", %{scope: scope, quiz: quiz} do
      for position <- 1..50 do
        question_fixture(scope, quiz, %{text: "Pergunta #{position}", position: position})
      end

      assert {:error, :question_limit_reached} = Quizzes.create_question(scope, quiz, attrs())
      assert Quizzes.get_quiz!(scope, quiz.id).questions_count == 50
    end

    test "still accepts the 50th question", %{scope: scope, quiz: quiz} do
      for position <- 1..49 do
        question_fixture(scope, quiz, %{text: "Pergunta #{position}", position: position})
      end

      assert {:ok, question} = Quizzes.create_question(scope, quiz, attrs())
      assert question.position == 50
    end
  end

  describe "update_question/3" do
    setup %{scope: scope, quiz: quiz} do
      {:ok, question} = Quizzes.create_question(scope, quiz, attrs())
      %{question: question}
    end

    test "updates the question text and the option texts, keeping the ids", %{
      scope: scope,
      question: question
    } do
      ids = Enum.map(question.answer_options, & &1.id)

      new_options =
        question.answer_options
        |> Enum.map(
          &%{
            id: &1.id,
            text: "#{&1.text} (revisado)",
            position: &1.position,
            is_correct: &1.is_correct
          }
        )

      assert {:ok, updated} =
               Quizzes.update_question(scope, question, %{
                 text: "Qual é a capital federal do Brasil?",
                 answer_options: new_options
               })

      assert updated.text == "Qual é a capital federal do Brasil?"
      assert Enum.map(updated.answer_options, & &1.id) == ids

      assert Enum.map(updated.answer_options, & &1.text) == [
               "Rio de Janeiro (revisado)",
               "Brasília (revisado)",
               "São Paulo (revisado)",
               "Salvador (revisado)"
             ]
    end

    test "moves the correct flag without tripping the partial unique index", %{
      scope: scope,
      question: question
    } do
      new_options =
        Enum.map(question.answer_options, fn option ->
          %{
            id: option.id,
            text: option.text,
            position: option.position,
            is_correct: option.position == 4
          }
        end)

      assert {:ok, updated} =
               Quizzes.update_question(scope, question, %{answer_options: new_options})

      assert Enum.map(updated.answer_options, & &1.is_correct) == [false, false, false, true]

      assert Enum.map(updated.answer_options, & &1.id) ==
               Enum.map(question.answer_options, & &1.id)
    end

    test "keeps the correct option when the edit does not move it", %{
      scope: scope,
      question: question
    } do
      new_options =
        Enum.map(question.answer_options, fn option ->
          %{
            id: option.id,
            text: "#{option.text}!",
            position: option.position,
            is_correct: option.is_correct
          }
        end)

      assert {:ok, updated} =
               Quizzes.update_question(scope, question, %{answer_options: new_options})

      assert Enum.map(updated.answer_options, & &1.is_correct) == [false, true, false, false]
    end

    test "keeps the correct option when only the question text changes", %{
      scope: scope,
      question: question
    } do
      assert {:ok, updated} = Quizzes.update_question(scope, question, %{text: "Só o enunciado"})

      assert updated.text == "Só o enunciado"
      assert Enum.map(updated.answer_options, & &1.is_correct) == [false, true, false, false]
    end

    test "does not change the position", %{scope: scope, quiz: quiz, question: question} do
      {:ok, second} = Quizzes.create_question(scope, quiz, attrs(%{text: "Segunda pergunta"}))

      assert {:ok, updated} = Quizzes.update_question(scope, second, %{position: 1})
      assert updated.position == 2
      assert Quizzes.get_question!(scope, quiz, question.id).position == 1
    end

    test "rejects an invalid set and leaves the stored question untouched", %{
      scope: scope,
      quiz: quiz,
      question: question
    } do
      two_correct =
        Enum.map(question.answer_options, fn option ->
          %{id: option.id, text: option.text, position: option.position, is_correct: true}
        end)

      assert {:error, changeset} =
               Quizzes.update_question(scope, question, %{answer_options: two_correct})

      assert "marque apenas uma alternativa correta" in errors_on(changeset).answer_options

      stored = Quizzes.get_question!(scope, quiz, question.id)
      assert Enum.map(stored.answer_options, & &1.is_correct) == [false, true, false, false]
    end

    test "raises for a question that belongs to somebody else", %{
      scope: scope,
      other_scope: other_scope,
      other_quiz: other_quiz
    } do
      {:ok, foreign} = Quizzes.create_question(other_scope, other_quiz, attrs())

      assert_raise Ecto.NoResultsError, fn ->
        Quizzes.update_question(scope, foreign, %{text: "Invadida"})
      end
    end
  end

  describe "get_question!/3" do
    test "returns the question with options ordered by position", %{scope: scope, quiz: quiz} do
      {:ok, question} = Quizzes.create_question(scope, quiz, attrs())

      loaded = Quizzes.get_question!(scope, quiz, question.id)

      assert loaded.id == question.id
      assert Enum.map(loaded.answer_options, & &1.position) == [1, 2, 3, 4]
    end

    test "accepts the id as a string", %{scope: scope, quiz: quiz} do
      {:ok, question} = Quizzes.create_question(scope, quiz, attrs())

      assert Quizzes.get_question!(scope, quiz, to_string(question.id)).id == question.id
    end

    test "raises for an id that does not exist", %{scope: scope, quiz: quiz} do
      assert_raise Ecto.NoResultsError, fn -> Quizzes.get_question!(scope, quiz, 0) end
    end

    test "raises for a question of another owner", %{
      scope: scope,
      other_scope: other_scope,
      other_quiz: other_quiz
    } do
      {:ok, foreign} = Quizzes.create_question(other_scope, other_quiz, attrs())

      assert_raise Ecto.NoResultsError, fn ->
        Quizzes.get_question!(scope, other_quiz, foreign.id)
      end
    end

    test "raises when the question belongs to another quiz of the same owner", %{
      scope: scope,
      quiz: quiz
    } do
      another = quiz_fixture(scope, %{title: "Outro quiz"})
      {:ok, question} = Quizzes.create_question(scope, quiz, attrs())

      assert_raise Ecto.NoResultsError, fn ->
        Quizzes.get_question!(scope, another, question.id)
      end
    end
  end

  describe "new_question/0 and change_question/2" do
    test "new_question/0 returns four blank options in positions 1..4" do
      question = Quizzes.new_question()

      assert question.text == nil
      assert Enum.map(question.answer_options, & &1.position) == [1, 2, 3, 4]
      assert Enum.all?(question.answer_options, &(&1.text == nil))
      assert Enum.all?(question.answer_options, &(&1.is_correct == false))
    end

    test "change_question/2 builds blank options for a brand new question" do
      changeset = Quizzes.change_question(%Question{})

      assert %Ecto.Changeset{} = changeset
      assert length(changeset.data.answer_options) == 4
    end

    test "change_question/2 keeps the options a question already has", %{
      scope: scope,
      quiz: quiz
    } do
      {:ok, question} = Quizzes.create_question(scope, quiz, attrs())

      changeset = Quizzes.change_question(question)

      assert Enum.map(changeset.data.answer_options, & &1.id) ==
               Enum.map(question.answer_options, & &1.id)
    end

    test "change_question/2 casts a full set onto a blank question without collapsing it" do
      # The position is assigned by create_question/3, so a form changeset only
      # stands on its own once it carries one.
      changeset = Quizzes.change_question(Quizzes.new_question(), attrs(%{position: 1}))

      assert changeset.valid?
      assert length(changeset.changes.answer_options) == 4

      assert changeset.changes.answer_options
             |> Enum.map(&Ecto.Changeset.get_field(&1, :position)) == [1, 2, 3, 4]
    end

    test "change_question/2 reports the set errors" do
      three = Enum.take(options(), 3)

      changeset = Quizzes.change_question(%Question{}, attrs(%{answer_options: three}))

      refute changeset.valid?
    end
  end
end
