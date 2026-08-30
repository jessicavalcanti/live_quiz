defmodule LiveQuizWeb.Api.V1.QuizController do
  @moduledoc """
  CRUD of quizzes over JSON.

  The controller holds no business rule: it translates parameters, calls
  `LiveQuiz.Quizzes` with the scope carried by the JWT and renders the view.
  Every function of the context filters by owner inside the query, so a quiz
  that belongs to somebody else is simply not found here.
  """

  use LiveQuizWeb, :controller

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Quizzes
  alias LiveQuiz.Quizzes.Quiz

  action_fallback LiveQuizWeb.Api.FallbackController

  @doc """
  Lists the quizzes of the authenticated user.

  Accepts `page`, `per_page` and `search`; invalid or missing values fall back
  to the defaults of the context instead of failing.
  """
  def index(conn, params) do
    page = Quizzes.list_quizzes(scope(conn), list_opts(params))

    render(conn, :index, page: page)
  end

  @doc """
  Shows one quiz with its questions and answer options, ordered by position.
  """
  def show(conn, %{"id" => id}) do
    with {:ok, %Quiz{} = quiz} <- fetch_quiz_with_questions(scope(conn), id) do
      render(conn, :show, quiz: quiz)
    end
  end

  @doc """
  Creates a quiz owned by the authenticated user.

  An `owner_id` sent in the body is ignored: the owner comes from the token.
  """
  def create(conn, params) do
    with {:ok, %Quiz{} = quiz} <- Quizzes.create_quiz(scope(conn), quiz_params(params)) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/api/v1/quizzes/#{quiz.id}")
      |> render(:show, quiz: quiz)
    end
  end

  @doc """
  Updates one quiz of the authenticated user. `PUT` and `PATCH` behave the same
  way: whatever the body carries is applied, the rest is left untouched.
  """
  def update(conn, %{"id" => id} = params) do
    scope = scope(conn)

    with {:ok, %Quiz{} = quiz} <- fetch_quiz_with_questions(scope, id),
         {:ok, %Quiz{} = quiz} <- Quizzes.update_quiz(scope, quiz, quiz_params(params)) do
      render(conn, :show, quiz: quiz)
    end
  end

  @doc """
  Deletes one quiz of the authenticated user, along with its questions and
  answer options.
  """
  def delete(conn, %{"id" => id}) do
    scope = scope(conn)

    with {:ok, %Quiz{} = quiz} <- fetch_quiz(scope, id),
         {:ok, %Quiz{}} <- Quizzes.delete_quiz(scope, quiz) do
      send_resp(conn, :no_content, "")
    end
  end

  defp scope(conn), do: conn.assigns.current_scope

  defp list_opts(params) do
    [
      page: Map.get(params, "page"),
      per_page: Map.get(params, "per_page"),
      search: Map.get(params, "search")
    ]
  end

  # Anything outside the `quiz` envelope is ignored, and a body without it is
  # treated as an empty quiz — the changeset answers with 422, never a 500.
  defp quiz_params(params) do
    case Map.get(params, "quiz") do
      attrs when is_map(attrs) -> attrs
      _other -> %{}
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
end
