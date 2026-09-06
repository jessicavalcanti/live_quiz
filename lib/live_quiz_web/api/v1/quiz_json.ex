defmodule LiveQuizWeb.Api.V1.QuizJSON do
  @moduledoc """
  Renders quizzes inside the `data` envelope of the API.

  Both the list and the detail go through the same serialization, so the two
  can never drift apart. Nested questions are delegated to
  `LiveQuizWeb.Api.V1.QuestionJSON`, which is the single source of that payload.
  `questions_count` and `playable` come ready from the context: this module
  counts nothing and touches no database.
  """

  alias LiveQuiz.Quizzes
  alias LiveQuiz.Quizzes.Quiz
  alias LiveQuizWeb.Api.V1.QuestionJSON

  @doc """
  Renders a page of quizzes: the entries in `data`, the pagination in `meta`.
  """
  def index(%{page: page}) do
    %{
      data: Enum.map(page.entries, &data/1),
      meta: %{
        page: page.page,
        per_page: page.per_page,
        total_entries: page.total_entries,
        total_pages: page.total_pages
      }
    }
  end

  @doc """
  Renders a single quiz with its questions and answer options.
  """
  def show(%{quiz: %Quiz{} = quiz}), do: %{data: data(quiz)}

  defp data(%Quiz{} = quiz) do
    %{
      id: quiz.id,
      title: quiz.title,
      description: quiz.description,
      questions_count: quiz.questions_count,
      playable: Quizzes.playable?(quiz),
      inserted_at: quiz.inserted_at,
      updated_at: quiz.updated_at
    }
    |> maybe_put_questions(quiz)
  end

  # The list never preloads questions, and a freshly created quiz has none:
  # in both cases the key is simply absent from the payload instead of lying
  # with an empty list.
  defp maybe_put_questions(data, %Quiz{questions: questions}) when is_list(questions) do
    Map.put(data, :questions, Enum.map(questions, &QuestionJSON.data/1))
  end

  defp maybe_put_questions(data, %Quiz{}), do: data
end
