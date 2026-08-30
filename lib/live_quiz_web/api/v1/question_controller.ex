defmodule LiveQuizWeb.Api.V1.QuestionController do
  @moduledoc """
  Questions and their answer options over JSON, nested under a quiz.

  Answer options never get a resource of their own: a question always carries
  exactly #{LiveQuiz.Quizzes.Question.options_per_question()} of them, so they
  travel nested in the question payload and are written in the same
  transaction.

  Like every controller of the API, this one holds no business rule. It reads
  the quiz through the scope carried by the JWT — which filters by owner inside
  the query — and hands the parameters to `LiveQuiz.Quizzes`. A quiz or a
  question that belongs to somebody else is simply not found here.
  """

  use LiveQuizWeb, :controller

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Quizzes
  alias LiveQuiz.Quizzes.Question
  alias LiveQuiz.Quizzes.Quiz

  action_fallback LiveQuizWeb.Api.FallbackController

  @directions %{"up" => :up, "down" => :down}

  @doc """
  Lists every question of the quiz, ordered by position, with its answer
  options. There is no pagination: the limit of
  #{Quizzes.max_questions()} questions keeps the list naturally small.
  """
  def index(conn, %{"quiz_id" => quiz_id}) do
    with {:ok, %Quiz{} = quiz} <- fetch_quiz_with_questions(scope(conn), quiz_id) do
      render(conn, :index, questions: quiz.questions)
    end
  end

  @doc """
  Shows one question of the quiz with its answer options.
  """
  def show(conn, %{"quiz_id" => quiz_id, "id" => id}) do
    scope = scope(conn)

    with {:ok, %Quiz{} = quiz} <- fetch_quiz(scope, quiz_id),
         {:ok, %Question{} = question} <- fetch_question(scope, quiz, id) do
      render(conn, :show, question: question)
    end
  end

  @doc """
  Creates a question at the end of the quiz.

  A `position` sent in the body is ignored: it is computed by the context. A
  quiz that already holds #{Quizzes.max_questions()} questions answers 422 and
  nothing is written.
  """
  def create(conn, %{"quiz_id" => quiz_id} = params) do
    scope = scope(conn)

    with {:ok, %Quiz{} = quiz} <- fetch_quiz(scope, quiz_id),
         {:ok, %Question{} = question} <-
           Quizzes.create_question(scope, quiz, question_params(params)) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/api/v1/quizzes/#{quiz.id}/questions/#{question.id}")
      |> render(:show, question: question)
    end
  end

  @doc """
  Updates the text and the answer options of one question. `PUT` and `PATCH`
  behave the same way, and neither changes the position — that is what `move`
  is for.

  Each answer option must carry its `id`, so the stored rows are updated
  instead of replaced.
  """
  def update(conn, %{"quiz_id" => quiz_id, "id" => id} = params) do
    scope = scope(conn)

    with {:ok, %Quiz{} = quiz} <- fetch_quiz(scope, quiz_id),
         {:ok, %Question{} = question} <- fetch_question(scope, quiz, id),
         {:ok, %Question{} = updated} <-
           Quizzes.update_question(scope, question, question_params(params)) do
      render(conn, :show, question: updated)
    end
  end

  @doc """
  Deletes one question. The answer options go with it and the remaining
  questions are renumbered by the context, keeping a dense `1..n` sequence.
  """
  def delete(conn, %{"quiz_id" => quiz_id, "id" => id}) do
    scope = scope(conn)

    with {:ok, %Quiz{} = quiz} <- fetch_quiz(scope, quiz_id),
         {:ok, %Question{} = question} <- fetch_question(scope, quiz, id),
         {:ok, %Question{}} <- Quizzes.delete_question(scope, question) do
      send_resp(conn, :no_content, "")
    end
  end

  @doc """
  Moves one question a single place `"up"` or `"down"` and answers with the
  whole reordered list, so the client never needs a follow-up `GET`.

  Moving the question that already sits at the matching edge is a successful
  no-op: 200 with the list unchanged.
  """
  def move(conn, %{"quiz_id" => quiz_id, "id" => id} = params) do
    scope = scope(conn)

    with {:ok, %Quiz{} = quiz} <- fetch_quiz(scope, quiz_id),
         {:ok, %Question{} = question} <- fetch_question(scope, quiz, id),
         {:ok, direction} <- fetch_direction(params),
         {:ok, _moved} <- Quizzes.move_question(scope, question, direction),
         {:ok, %Quiz{} = quiz} <- fetch_quiz_with_questions(scope, quiz_id) do
      render(conn, :index, questions: quiz.questions)
    end
  end

  defp scope(conn), do: conn.assigns.current_scope

  # Anything outside the `question` envelope is ignored, and a body without it
  # is treated as an empty question — the changeset answers with 422, never a
  # 500.
  defp question_params(params) do
    case Map.get(params, "question") do
      attrs when is_map(attrs) -> attrs
      _other -> %{}
    end
  end

  # Only "up" and "down" exist. Anything else — including a missing key — is a
  # malformed body, not a rule of the domain, so it never reaches the context.
  defp fetch_direction(params) do
    case Map.fetch(@directions, Map.get(params, "direction")) do
      {:ok, direction} -> {:ok, direction}
      :error -> {:error, :invalid_direction}
    end
  end

  # The context reads with bang functions, exactly like the LiveViews do. The
  # rescue lives here, in one place, so the actions stay free of `try/rescue`
  # and the `FallbackController` renders the 404 envelope of the API.
  defp fetch_quiz(%Scope{} = scope, id) do
    {:ok, Quizzes.get_quiz!(scope, id)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp fetch_quiz_with_questions(%Scope{} = scope, id) do
    {:ok, Quizzes.get_quiz_with_questions!(scope, id)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp fetch_question(%Scope{} = scope, %Quiz{} = quiz, id) do
    {:ok, Quizzes.get_question!(scope, quiz, id)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end
end
