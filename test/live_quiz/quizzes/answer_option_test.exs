defmodule LiveQuiz.Quizzes.AnswerOptionTest do
  use LiveQuiz.DataCase, async: true

  alias LiveQuiz.Quizzes.AnswerOption

  defp valid_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{text: "Brasília", position: 1, is_correct: true})
  end

  describe "changeset/2" do
    test "is valid with text, position and the correct flag" do
      assert AnswerOption.changeset(%AnswerOption{}, valid_attrs()).valid?
    end

    test "defaults is_correct to false" do
      changeset = AnswerOption.changeset(%AnswerOption{}, %{text: "Recife", position: 2})

      assert changeset.valid?
      assert apply_changes(changeset).is_correct == false
    end

    test "requires the text" do
      changeset = AnswerOption.changeset(%AnswerOption{}, valid_attrs(%{text: ""}))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).text
    end

    test "keeps a text cleared on an existing option as blank" do
      changeset = AnswerOption.changeset(%AnswerOption{text: "Antiga"}, valid_attrs(%{text: nil}))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).text
    end

    test "trims the text before validating it" do
      changeset = AnswerOption.changeset(%AnswerOption{}, valid_attrs(%{text: "  Brasília  "}))

      assert changeset.valid?
      assert get_change(changeset, :text) == "Brasília"
    end

    test "rejects text longer than 200 characters" do
      attrs = valid_attrs(%{text: String.duplicate("a", 201)})
      changeset = AnswerOption.changeset(%AnswerOption{}, attrs)

      refute changeset.valid?
      assert "should be at most 200 character(s)" in errors_on(changeset).text
    end

    test "requires the position" do
      changeset = AnswerOption.changeset(%AnswerOption{}, valid_attrs(%{position: nil}))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).position
    end

    test "rejects a position below 1" do
      changeset = AnswerOption.changeset(%AnswerOption{}, valid_attrs(%{position: 0}))

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).position
    end

    test "rejects a position above 4" do
      changeset = AnswerOption.changeset(%AnswerOption{}, valid_attrs(%{position: 5}))

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).position
    end

    test "accepts every position from 1 to 4" do
      for position <- 1..4 do
        assert AnswerOption.changeset(%AnswerOption{}, valid_attrs(%{position: position})).valid?
      end
    end
  end
end
