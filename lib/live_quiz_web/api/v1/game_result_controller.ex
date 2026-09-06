defmodule LiveQuizWeb.Api.V1.GameResultController do
  @moduledoc """
  Ranking, results and history endpoints for the v1 API.

  This controller only resolves the room and translates parameters. Visibility,
  ownership and the finished-match rule remain in `LiveQuiz.Games`.
  """

  use LiveQuizWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias LiveQuiz.Games
  alias LiveQuizWeb.Api.V1.Schemas.ErrorResponse
  alias LiveQuizWeb.Api.V1.Schemas.GameResultListResponse
  alias LiveQuizWeb.Api.V1.Schemas.GameResultResponse
  alias LiveQuizWeb.Api.V1.Schemas.RankingResponse

  action_fallback LiveQuizWeb.Api.FallbackController
  tags ["Resultados"]

  @code [in: :path, type: :string, required: true, description: "Código da partida"]
  @quiz_id [in: :path, type: :integer, required: true, description: "Identificador do quiz"]
  @history_parameters [
    page: [in: :query, type: :integer],
    per_page: [in: :query, type: :integer],
    quiz_id: [in: :query, type: :integer],
    from: [in: :query, type: :string],
    to: [in: :query, type: :string]
  ]

  @doc "Returns the current ranking to the host or a participant."
  operation :ranking,
    summary: "Consulta o ranking da partida",
    description: "Retorna o ranking ordenado da partida para o host ou participante autorizado.",
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
         {:ok, ranking} <- Games.current_ranking(session, viewer(conn)) do
      render(conn, :ranking, ranking: ranking)
    end
  end

  @doc "Returns the complete immutable result to the host."
  operation :results,
    summary: "Consulta o resultado completo da partida",
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
    security: [%{"bearerAuth" => []}],
    parameters: @history_parameters,
    responses: [
      ok: {"Histórico", "application/json", GameResultListResponse},
      unauthorized: {"Não autenticado", "application/json", ErrorResponse},
      unprocessable_entity: {"Filtro inválido", "application/json", ErrorResponse}
    ]

  def my_history(conn, params) do
    with {:ok, filters} <- filters(params),
         {:ok, pagination} <- pagination(params) do
      page = Games.list_game_results(scope(conn), filters, pagination)
      render(conn, :history, page: page)
    end
  end

  @doc "Lists finished matches for a quiz owned by the authenticated host."
  operation :quiz_history,
    summary: "Lista o histórico de um quiz",
    security: [%{"bearerAuth" => []}],
    parameters: [quiz_id: @quiz_id] ++ @history_parameters,
    responses: [
      ok: {"Histórico do quiz", "application/json", GameResultListResponse},
      unauthorized: {"Não autenticado", "application/json", ErrorResponse},
      not_found: {"Quiz inexistente ou sem acesso", "application/json", ErrorResponse},
      unprocessable_entity: {"Filtro inválido", "application/json", ErrorResponse}
    ]

  def quiz_history(conn, %{"quiz_id" => quiz_id} = params) do
    with {:ok, quiz_id} <- positive_integer(quiz_id),
         {:ok, filters} <- filters(params),
         {:ok, pagination} <- pagination(params) do
      page = Games.list_quiz_game_history(scope(conn), quiz_id, filters, pagination)
      render(conn, :quiz_history, page: page)
    end
  end

  defp viewer(conn), do: conn.assigns[:current_scope] || conn.assigns[:current_participant]
  defp scope(conn), do: conn.assigns.current_scope

  defp pagination(params) do
    with {:ok, page} <- optional_positive_integer(params["page"]),
         {:ok, per_page} <- optional_positive_integer(params["per_page"]),
         :ok <- valid_per_page(per_page) do
      {:ok, %{page: page, per_page: per_page}}
    end
  end

  defp valid_per_page(nil), do: :ok
  defp valid_per_page(value) when value in 1..100, do: :ok
  defp valid_per_page(_value), do: {:error, :invalid_filter}

  defp filters(params) do
    with {:ok, quiz_id} <- optional_positive_integer(params["quiz_id"]),
         {:ok, from} <- optional_date(params["from"]),
         {:ok, to} <- optional_date(params["to"]) do
      {:ok, %{quiz_id: quiz_id, from: from, to: to}}
    end
  end

  defp optional_positive_integer(nil), do: {:ok, nil}
  defp optional_positive_integer(""), do: {:ok, nil}
  defp optional_positive_integer(value), do: positive_integer(value)

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> {:error, :invalid_filter}
    end
  end

  defp positive_integer(_value), do: {:error, :invalid_filter}

  defp optional_date(nil), do: {:ok, nil}
  defp optional_date(""), do: {:ok, nil}

  defp optional_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}
      _ -> {:error, :invalid_filter}
    end
  end

  defp optional_date(_value), do: {:error, :invalid_filter}
end
