defmodule LiveQuizWeb.Api.V1.GameResultController do
  @moduledoc """
  Ranking, results and history endpoints for the v1 API.

  This controller only resolves the room and translates parameters. Visibility,
  ownership and the finished-match rule remain in `LiveQuiz.Games`.
  """

  use LiveQuizWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias LiveQuiz.Games
  alias LiveQuiz.Games.ResultFilters
  alias LiveQuiz.Pagination
  alias LiveQuizWeb.Api.V1.Schemas.ErrorResponse
  alias LiveQuizWeb.Api.V1.Schemas.GameHistoryResponse
  alias LiveQuizWeb.Api.V1.Schemas.GameResultListResponse
  alias LiveQuizWeb.Api.V1.Schemas.GameResultResponse
  alias LiveQuizWeb.Api.V1.Schemas.RankingResponse
  alias LiveQuizWeb.Api.Viewer

  action_fallback LiveQuizWeb.Api.FallbackController
  tags ["Resultados"]

  @code [in: :path, type: :string, required: true, description: "Código da partida"]
  @quiz_id [in: :path, type: :integer, required: true, description: "Identificador do quiz"]
  @history_parameters [
    page: [in: :query, type: :integer, description: "Página (padrão 1)", example: 1],
    per_page: [
      in: :query,
      type: :integer,
      description: "Itens por página (padrão 20, máximo 100)",
      example: 20
    ],
    quiz_id: [in: :query, type: :integer, description: "Filtra pelo quiz", example: 7],
    from: [
      in: :query,
      type: :string,
      description: "Data inicial inclusiva (AAAA-MM-DD)",
      example: "2026-09-01"
    ],
    to: [
      in: :query,
      type: :string,
      description: "Data final inclusiva (AAAA-MM-DD)",
      example: "2026-09-30"
    ]
  ]

  @doc "Returns the current ranking to the host or a participant."
  operation :ranking,
    summary: "Consulta o ranking da partida",
    description:
      "Retorna o ranking ordenado da partida para o host ou participante autorizado. O ranking só fica disponível para uma identidade que tenha acesso à partida.",
    security: [%{"participantAuth" => []}, %{"bearerAuth" => []}],
    parameters: [code: @code],
    responses: [
      ok: {"Ranking", "application/json", RankingResponse},
      unauthorized: {"Credencial ausente", "application/json", ErrorResponse},
      forbidden: {"Não participa desta partida", "application/json", ErrorResponse},
      not_found: {"Partida inexistente", "application/json", ErrorResponse}
    ]

  def ranking(conn, %{"code" => code}) do
    with {:ok, session} <- Games.get_match_by_code(code),
         {:ok, ranking} <- Viewer.read(conn, &Games.current_ranking(session, &1)) do
      render(conn, :ranking, ranking: ranking)
    end
  end

  @doc "Returns the complete immutable result to the host."
  operation :results,
    summary: "Consulta o resultado completo da partida",
    description:
      "Retorna a partida encerrada e todos os resultados. Operação restrita ao host autenticado; participantes devem usar o resultado individual.",
    security: [%{"bearerAuth" => []}],
    parameters: [code: @code],
    responses: [
      ok: {"Resultado completo", "application/json", GameResultListResponse},
      unauthorized: {"Não autenticado", "application/json", ErrorResponse},
      not_found: {"Partida inexistente ou sem acesso", "application/json", ErrorResponse}
    ]

  def results(conn, %{"code" => code}) do
    with {:ok, session} <- Games.get_match_by_code(code),
         {:ok, session} <- Games.get_host_game_history(scope(conn), session.id) do
      render(conn, :results, session: session)
    end
  end

  @doc "Returns only the authenticated participant's immutable result."
  operation :my_result,
    summary: "Consulta o próprio resultado",
    description: "Retorna somente o resultado do participante autenticado na partida encerrada.",
    security: [%{"bearerAuth" => []}],
    parameters: [code: @code],
    responses: [
      ok: {"Resultado individual", "application/json", GameResultResponse},
      unauthorized: {"Não autenticado", "application/json", ErrorResponse},
      not_found: {"Resultado inexistente", "application/json", ErrorResponse}
    ]

  def my_result(conn, %{"code" => code}) do
    with {:ok, session} <- Games.get_match_by_code(code),
         {:ok, result} <- Games.get_my_game_result_for_session(scope(conn), session.id) do
      render(conn, :result, result: result)
    end
  end

  @doc "Lists the authenticated user's finished results."
  operation :my_history,
    summary: "Lista o histórico do usuário",
    description:
      "Lista resultados de partidas encerradas pertencentes ao usuário do JWT. Aceita paginação e filtros opcionais por quiz e intervalo de datas; datas são interpretadas em UTC.",
    security: [%{"bearerAuth" => []}],
    parameters: @history_parameters,
    responses: [
      ok: {"Histórico", "application/json", GameResultListResponse},
      unauthorized: {"Não autenticado", "application/json", ErrorResponse},
      unprocessable_entity: {"Filtro inválido", "application/json", ErrorResponse}
    ]

  def my_history(conn, params) do
    with {:ok, filters} <- ResultFilters.parse(params),
         {:ok, pagination} <- Pagination.parse(params) do
      page = Games.list_game_results(scope(conn), filters, pagination)
      render(conn, :history, page: page)
    end
  end

  @doc "Lists finished matches for a quiz owned by the authenticated host."
  operation :quiz_history,
    summary: "Lista o histórico de um quiz",
    description:
      "Lista partidas encerradas do quiz pertencente ao host autenticado. Aceita paginação e filtros opcionais por quiz e intervalo de datas; datas são interpretadas em UTC.",
    security: [%{"bearerAuth" => []}],
    parameters: [quiz_id: @quiz_id] ++ @history_parameters,
    responses: [
      ok: {"Histórico do quiz", "application/json", GameHistoryResponse},
      unauthorized: {"Não autenticado", "application/json", ErrorResponse},
      not_found: {"Quiz inexistente ou sem acesso", "application/json", ErrorResponse},
      unprocessable_entity: {"Filtro inválido", "application/json", ErrorResponse}
    ]

  def quiz_history(conn, %{"quiz_id" => quiz_id} = params) do
    with {:ok, quiz_id} <- ResultFilters.required_quiz_id(quiz_id),
         {:ok, filters} <- ResultFilters.parse(params),
         {:ok, pagination} <- Pagination.parse(params) do
      page = Games.list_quiz_game_history(scope(conn), quiz_id, filters, pagination)
      render(conn, :quiz_history, page: page)
    end
  end

  defp scope(conn), do: conn.assigns.current_scope
end
