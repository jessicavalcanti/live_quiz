defmodule LiveQuizWeb.GameHistoryLive.Show do
  @moduledoc "Complete ranking for one finished match, visible to its host."

  use LiveQuizWeb, :live_view

  alias LiveQuiz.Games
  alias LiveQuizWeb.Formatters

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Games.get_host_game_history(socket.assigns.current_scope, id) do
      {:ok, session} -> {:ok, assign(socket, page_title: "Ranking da partida", session: session)}
      {:error, :not_found} -> raise Ecto.NoResultsError, queryable: LiveQuiz.Games.GameSession
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="host-game-history-detail" class="space-y-8">
        <.link navigate={~p"/game-history"} class="link link-primary">← Voltar para o histórico</.link>
        <div>
          <p class="text-sm font-semibold uppercase tracking-wider text-primary">
            Partida finalizada
          </p>
          <h1 class="mt-2 text-3xl font-bold">{@session.quiz_title}</h1>
          <p class="mt-2 text-base-content/70">
            Realizada em {Formatters.format_datetime(@session.finished_at)}
          </p>
        </div>
        <section aria-labelledby="host-ranking-heading">
          <h2 id="host-ranking-heading" class="text-2xl font-bold">Ranking completo</h2>
          <div id="host-ranking" class="mt-4 overflow-x-auto rounded-box border border-base-300">
            <table class="table">
              <thead>
                <tr>
                  <th>Posição</th><th>Participante</th><th>Acertos</th><th>Pontuação</th><th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={result <- @session.game_results} id={"host-ranking-result-#{result.id}"}>
                  <td>{result.final_position}º</td><td>{result.nickname}</td>
                  <td>{Formatters.format_correct_answers(result.correct_answers)}</td>
                  <td>{Formatters.format_score(result.score)}</td>
                  <td>
                    <.link
                      navigate={~p"/game-history/#{@session.id}/participants/#{result.id}"}
                      class="link link-primary"
                    >Detalhes</.link>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
