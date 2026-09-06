defmodule LiveQuiz.Quizzes.QuizTest do
  use LiveQuiz.DataCase, async: true

  alias LiveQuiz.Quizzes.Quiz
  alias LiveQuizWeb.CoreComponents

  defp valid_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{title: "Capitais do Brasil", description: "Um quiz sobre capitais."})
  end

  describe "changeset/2" do
    test "is valid with a title and a description" do
      changeset = Quiz.changeset(%Quiz{}, valid_attrs())

      assert changeset.valid?
      assert get_change(changeset, :title) == "Capitais do Brasil"
    end

    test "is valid without a description" do
      assert Quiz.changeset(%Quiz{}, valid_attrs(%{description: nil})).valid?
    end

    test "requires a title" do
      changeset = Quiz.changeset(%Quiz{}, valid_attrs(%{title: nil}))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).title
    end

    test "rejects a title shorter than 3 characters" do
      changeset = Quiz.changeset(%Quiz{}, valid_attrs(%{title: "AB"}))

      refute changeset.valid?
      assert "should be at least 3 character(s)" in errors_on(changeset).title
    end

    test "rejects a title longer than 120 characters" do
      changeset = Quiz.changeset(%Quiz{}, valid_attrs(%{title: String.duplicate("a", 121)}))

      refute changeset.valid?
      assert "should be at most 120 character(s)" in errors_on(changeset).title
    end

    test "rejects a description longer than 500 characters" do
      changeset = Quiz.changeset(%Quiz{}, valid_attrs(%{description: String.duplicate("a", 501)}))

      refute changeset.valid?
      assert "should be at most 500 character(s)" in errors_on(changeset).description
    end

    test "trims the title before validating it" do
      changeset = Quiz.changeset(%Quiz{}, valid_attrs(%{title: "   Geografia   "}))

      assert changeset.valid?
      assert get_change(changeset, :title) == "Geografia"
    end

    test "counts a whitespace-only title as blank" do
      changeset = Quiz.changeset(%Quiz{}, valid_attrs(%{title: "   "}))

      refute changeset.valid?
    end

    test "keeps a title cleared on an existing quiz as blank" do
      changeset = Quiz.changeset(%Quiz{title: "Antigo"}, valid_attrs(%{title: nil}))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).title
    end
  end

  describe "error messages in pt-BR" do
    test "translates a blank title" do
      changeset = Quiz.changeset(%Quiz{}, valid_attrs(%{title: nil}))

      assert translated(changeset, :title) == ["não pode ficar em branco"]
    end

    test "translates the minimum length" do
      changeset = Quiz.changeset(%Quiz{}, valid_attrs(%{title: "AB"}))

      assert translated(changeset, :title) == ["deve ter pelo menos 3 caracteres"]
    end

    test "translates the maximum length" do
      changeset = Quiz.changeset(%Quiz{}, valid_attrs(%{description: String.duplicate("a", 501)}))

      assert translated(changeset, :description) == ["deve ter no máximo 500 caracteres"]
    end
  end

  defp translated(changeset, field) do
    CoreComponents.translate_errors(changeset.errors, field)
  end
end
