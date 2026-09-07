defmodule LiveQuizWeb.GameHistoryLive.Participant do
  @moduledoc """
  Immutable answer details for one participant, visible to the host.

  The block itself is `LiveQuizWeb.ResultDetail`, shared with the participant's
  own view of the same match: what belongs to this screen is that the host got
  here from a ranking, and that the name at the top is somebody else's (R41).
  """

  use LiveQuizWeb, :live_view

  import LiveQuizWeb.ResultDetail

  alias LiveQuiz.Games

  @impl true
  def mount(%{"result_id" => id, "id" => session_id}, _session, socket) do
    with {:ok, result} <- Games.get_host_game_result(socket.assigns.current_scope, id),
         true <- to_string(result.game_session_id) == session_id do
      {:ok, assign(socket, page_title: "Detalhes do participante", result: result)}
    else
      _ -> raise Ecto.NoResultsError, queryable: LiveQuiz.Games.GameResult
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.result_detail
        id="host-participant-result"
        result={@result}
        heading="Respostas por pergunta"
      >
        <:header>
          <.link navigate={~p"/game-history/#{@result.game_session_id}"} class="link link-primary">
            ← Voltar para o ranking
          </.link>

          <div>
            <p class="text-sm font-semibold tracking-wider text-primary uppercase">
              Desempenho individual
            </p>
            <h1 class="mt-2 text-3xl font-bold">{@result.nickname}</h1>
            <p class="mt-2 text-base-content/70">{@result.quiz_title}</p>
          </div>
        </:header>
      </.result_detail>
    </Layouts.app>
    """
  end
end
