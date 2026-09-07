defmodule LiveQuizWeb.GameResultLive.Show do
  @moduledoc """
  Detailed immutable result for the authenticated participant.

  The block itself is `LiveQuizWeb.ResultDetail`, shared with the host's view of
  one participant: what belongs to this screen is how somebody arrives at it and
  what it is called (R41).
  """

  use LiveQuizWeb, :live_view

  import LiveQuizWeb.ResultDetail

  alias LiveQuiz.Games
  alias LiveQuizWeb.Formatters

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Games.get_my_game_result(socket.assigns.current_scope, id) do
      {:ok, result} ->
        {:ok, assign(socket, page_title: "Detalhes da partida", result: result)}

      {:error, :not_found} ->
        raise Ecto.NoResultsError, queryable: LiveQuiz.Games.GameResult
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.result_detail id="game-result-detail" result={@result} heading="Detalhes por pergunta">
        <:header>
          <.link navigate={~p"/game-results"} class="link link-primary">
            ← Voltar para minhas partidas
          </.link>

          <div>
            <p class="text-sm font-semibold tracking-wider text-primary uppercase">Resultado final</p>
            <h1 class="mt-2 text-3xl font-bold">{@result.quiz_title}</h1>
            <p class="mt-2 text-base-content/70">
              Realizada em {Formatters.format_datetime(@result.inserted_at)}
            </p>
          </div>
        </:header>
      </.result_detail>
    </Layouts.app>
    """
  end
end
