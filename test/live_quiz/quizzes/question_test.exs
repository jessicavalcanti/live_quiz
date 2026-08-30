defmodule LiveQuiz.Quizzes.QuestionTest do
  use LiveQuiz.DataCase, async: true

  import LiveQuiz.QuizzesFixtures

  alias LiveQuiz.Quizzes.Question

  defp valid_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      text: "Qual é a capital do Brasil?",
      position: 1,
      answer_options: valid_answer_options_attributes()
    })
  end

  describe "changeset/2" do
    test "is valid with text, position and answer options" do
      changeset = Question.changeset(%Question{}, valid_attrs())

      assert changeset.valid?
      assert length(get_change(changeset, :answer_options)) == 4
    end

    test "requires the text" do
      changeset = Question.changeset(%Question{}, valid_attrs(%{text: nil}))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).text
    end

    test "rejects text shorter than 3 characters" do
      changeset = Question.changeset(%Question{}, valid_attrs(%{text: "Oi"}))

      refute changeset.valid?
      assert "should be at least 3 character(s)" in errors_on(changeset).text
    end

    test "rejects text longer than 500 characters" do
      changeset =
        Question.changeset(%Question{}, valid_attrs(%{text: String.duplicate("a", 501)}))

      refute changeset.valid?
      assert "should be at most 500 character(s)" in errors_on(changeset).text
    end

    test "requires the position" do
      changeset = Question.changeset(%Question{}, valid_attrs(%{position: nil}))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).position
    end

    test "rejects position zero" do
      changeset = Question.changeset(%Question{}, valid_attrs(%{position: 0}))

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).position
    end

    test "rejects a negative position" do
      changeset = Question.changeset(%Question{}, valid_attrs(%{position: -1}))

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).position
    end

    test "requires the answer options" do
      changeset = Question.changeset(%Question{}, valid_attrs(%{answer_options: []}))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).answer_options
    end

    test "propagates the errors of an invalid answer option" do
      options = [%{text: "", position: 1, is_correct: true}]
      changeset = Question.changeset(%Question{}, valid_attrs(%{answer_options: options}))

      refute changeset.valid?
      assert [%{text: ["can't be blank"]}] = errors_on(changeset).answer_options
    end

    test "does not enforce the set rules that belong to F1-07" do
      options = [
        %{text: "Brasília", position: 1, is_correct: true},
        %{text: "Recife", position: 2, is_correct: false}
      ]

      assert Question.changeset(%Question{}, valid_attrs(%{answer_options: options})).valid?
    end
  end
end
