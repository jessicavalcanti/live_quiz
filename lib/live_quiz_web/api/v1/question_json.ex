defmodule LiveQuizWeb.Api.V1.QuestionJSON do
  @moduledoc """
  Renders questions and their answer options inside the `data` envelope.

  This module is the single source of the question payload: the quiz detail
  reuses `data/1` from here, so a question serialized under a quiz and a
  question serialized on its own can never drift apart.
  """

  alias LiveQuiz.Quizzes.AnswerOption
  alias LiveQuiz.Quizzes.Question

  @doc """
  Renders the questions of a quiz as a plain list, already ordered by position.

  There is no `meta`: the endpoint is not paginated.
  """
  def index(%{questions: questions}), do: %{data: Enum.map(questions, &data/1)}

  @doc """
  Renders a single question.
  """
  def show(%{question: %Question{} = question}), do: %{data: data(question)}

  @doc """
  Serializes one question with its answer options.
  """
  def data(%Question{} = question) do
    %{
      id: question.id,
      text: question.text,
      position: question.position,
      answer_options: Enum.map(question.answer_options, &answer_option/1)
    }
  end

  defp answer_option(%AnswerOption{} = option) do
    %{
      id: option.id,
      text: option.text,
      position: option.position,
      is_correct: option.is_correct
    }
  end
end
