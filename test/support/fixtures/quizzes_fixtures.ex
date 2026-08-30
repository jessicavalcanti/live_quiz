defmodule LiveQuiz.QuizzesFixtures do
  @moduledoc """
  Test helpers for creating quizzes, questions and answer options.

  Both fixtures take a `Scope` instead of a `%User{}` so they mirror the
  signature the `LiveQuiz.Quizzes` context functions will have. They insert
  through the schemas directly because the context does not exist yet (F1-06).
  """

  import Ecto.Query

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Quizzes.AnswerOption
  alias LiveQuiz.Quizzes.Question
  alias LiveQuiz.Quizzes.Quiz
  alias LiveQuiz.Repo

  def valid_quiz_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      title: "Capitais do Brasil",
      description: "Um quiz sobre as capitais dos estados brasileiros."
    })
  end

  @doc """
  Four valid options, the first one being the correct answer.
  """
  def valid_answer_options_attributes(attrs \\ []) do
    defaults = [
      %{text: "Brasília", position: 1, is_correct: true},
      %{text: "Rio de Janeiro", position: 2, is_correct: false},
      %{text: "São Paulo", position: 3, is_correct: false},
      %{text: "Salvador", position: 4, is_correct: false}
    ]

    case attrs do
      [] -> defaults
      given -> given
    end
  end

  def valid_question_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      text: "Qual é a capital do Brasil?",
      answer_options: valid_answer_options_attributes()
    })
  end

  @spec quiz_fixture(Scope.t(), map()) :: Quiz.t()
  def quiz_fixture(%Scope{} = scope, attrs \\ %{}) do
    %Quiz{owner_id: scope.user.id}
    |> Quiz.changeset(valid_quiz_attributes(attrs))
    |> Repo.insert!()
  end

  @spec question_fixture(Scope.t(), Quiz.t(), map()) :: Question.t()
  def question_fixture(%Scope{} = _scope, %Quiz{} = quiz, attrs \\ %{}) do
    attrs =
      attrs
      |> valid_question_attributes()
      |> Map.put_new_lazy(:position, fn -> next_question_position(quiz) end)

    %Question{quiz_id: quiz.id}
    |> Question.changeset(attrs)
    |> Repo.insert!()
  end

  @doc """
  Inserts a single option, bypassing the question changeset, so tests can drive
  the database constraints directly.
  """
  def insert_answer_option!(%Question{} = question, attrs) do
    %AnswerOption{question_id: question.id}
    |> AnswerOption.changeset(attrs)
    |> Repo.insert!()
  end

  defp next_question_position(%Quiz{} = quiz) do
    position =
      Repo.one(from q in Question, where: q.quiz_id == ^quiz.id, select: max(q.position))

    (position || 0) + 1
  end
end
