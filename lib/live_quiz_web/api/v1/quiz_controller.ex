defmodule LiveQuizWeb.Api.V1.QuizController do
  @moduledoc """
  CRUD of quizzes over JSON.

  The controller holds no business rule: it translates parameters, calls
  `LiveQuiz.Quizzes` with the scope carried by the JWT and renders the view.
  Every function of the context filters by owner inside the query, so a quiz
  that belongs to somebody else is simply not found here.
  """

  use LiveQuizWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Pagination
  alias LiveQuiz.Quizzes
  alias LiveQuiz.Quizzes.Quiz
  alias LiveQuizWeb.Api.V1.Schemas.ErrorResponse
  alias LiveQuizWeb.Api.V1.Schemas.QuizListResponse
  alias LiveQuizWeb.Api.V1.Schemas.QuizRequest
  alias LiveQuizWeb.Api.V1.Schemas.QuizResponse
  alias LiveQuizWeb.Api.V1.Schemas.ValidationErrorResponse

  action_fallback LiveQuizWeb.Api.FallbackController

  tags ["Quizzes"]
  security [%{"bearerAuth" => []}]

  @quiz_id_parameter [
    in: :path,
    description: "Identificador do quiz",
    type: :integer,
    required: true,
    example: 1
  ]

  @doc """
  Lists the quizzes of the authenticated user.

  Accepts `page`, `per_page` and `search`. A missing value is the default; a
  present one that is not a page anybody could have is refused with `422`,
  the same as every other listing of the API.
  """
  operation :index,
    summary: "Lista os quizzes do usuário autenticado",
    description:
      "Página os quizzes do dono do token. Paginação ausente cai no padrão; paginação inválida é recusada com 422.",
    parameters: [
      page: [in: :query, type: :integer, description: "Página (padrão 1)", example: 1],
      per_page: [
        in: :query,
        type: :integer,
        description: "Itens por página (padrão 20, máximo 100)",
        example: 20
      ],
      search: [in: :query, type: :string, description: "Filtra pelo título", example: "geo"]
    ],
    responses: [
      ok: {"Página de quizzes", "application/json", QuizListResponse},
      unauthorized: {"Não autenticado", "application/json", ErrorResponse},
      unprocessable_entity: {"Paginação inválida", "application/json", ErrorResponse}
    ]

  def index(conn, params) do
    with {:ok, pagination} <- Pagination.parse(params) do
      page = Quizzes.list_quizzes(scope(conn), list_opts(pagination, params))

      render(conn, :index, page: page)
    end
  end

  @doc """
  Shows one quiz with its questions and answer options, ordered by position.
  """
  operation :show,
    summary: "Detalha um quiz com as suas perguntas",
    parameters: [id: @quiz_id_parameter],
    responses: [
      ok: {"Quiz encontrado", "application/json", QuizResponse},
      unauthorized: {"Não autenticado", "application/json", ErrorResponse},
      not_found: {"Quiz inexistente ou de outro dono", "application/json", ErrorResponse}
    ]

  def show(conn, %{"id" => id}) do
    with {:ok, %Quiz{} = quiz} <- fetch_quiz_with_questions(scope(conn), id) do
      render(conn, :show, quiz: quiz)
    end
  end

  @doc """
  Creates a quiz owned by the authenticated user.

  An `owner_id` sent in the body is ignored: the owner comes from the token.
  """
  operation :create,
    summary: "Cria um quiz",
    description: "O dono vem do token: um `owner_id` enviado no corpo é ignorado.",
    request_body: {"Atributos do quiz", "application/json", QuizRequest, required: true},
    responses: [
      created: {"Quiz criado, com o header Location", "application/json", QuizResponse},
      unauthorized: {"Não autenticado", "application/json", ErrorResponse},
      unprocessable_entity: {"Quiz inválido", "application/json", ValidationErrorResponse}
    ]

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
  operation :update,
    summary: "Atualiza um quiz",
    description: "`PUT` e `PATCH` se comportam da mesma forma.",
    parameters: [id: @quiz_id_parameter],
    request_body: {"Atributos do quiz", "application/json", QuizRequest, required: true},
    responses: [
      ok: {"Quiz atualizado", "application/json", QuizResponse},
      unauthorized: {"Não autenticado", "application/json", ErrorResponse},
      not_found: {"Quiz inexistente ou de outro dono", "application/json", ErrorResponse},
      conflict: {"Quiz com sala ativa", "application/json", ErrorResponse},
      unprocessable_entity: {"Quiz inválido", "application/json", ValidationErrorResponse}
    ]

  def update(conn, %{"id" => id} = params) do
    scope = scope(conn)

    with {:ok, %Quiz{} = quiz} <- fetch_quiz_with_questions(scope, id),
         {:ok, %Quiz{}} <- Quizzes.update_quiz(scope, quiz, quiz_params(params)),
         # Read back for the render rather than serializing what the write
         # returned: the context answers with the quiz it wrote, and this
         # representation carries the questions alongside it.
         {:ok, %Quiz{} = updated} <- fetch_quiz_with_questions(scope, id) do
      render(conn, :show, quiz: updated)
    end
  end

  @doc """
  Deletes one quiz of the authenticated user, along with its questions and
  answer options.
  """
  operation :delete,
    summary: "Exclui um quiz",
    description: "As perguntas e as alternativas do quiz vão junto, em cascata.",
    parameters: [id: @quiz_id_parameter],
    responses: [
      no_content: "Quiz excluído",
      unauthorized: {"Não autenticado", "application/json", ErrorResponse},
      not_found: {"Quiz inexistente ou de outro dono", "application/json", ErrorResponse},
      conflict: {"Quiz com sala ativa", "application/json", ErrorResponse}
    ]

  def delete(conn, %{"id" => id}) do
    scope = scope(conn)

    with {:ok, %Quiz{} = quiz} <- fetch_quiz(scope, id),
         {:ok, %Quiz{}} <- Quizzes.delete_quiz(scope, quiz) do
      send_resp(conn, :no_content, "")
    end
  end

  defp scope(conn), do: conn.assigns.current_scope

  defp list_opts(%{page: page, per_page: per_page}, params) do
    [page: page, per_page: per_page, search: Map.get(params, "search")]
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
