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
        <.back_button
          id="back-to-game-history"
          navigate={~p"/game-history"}
          label="Voltar para o histórico"
        />

        <div>
          <p class="text-sm font-medium tracking-wider text-muted-foreground uppercase">
            Partida finalizada
          </p>
          <h1 class="mt-2 text-3xl font-semibold tracking-tight">{@session.quiz_title}</h1>
          <p class="mt-2 text-muted-foreground">
            Realizada em {Formatters.format_datetime(@session.finished_at)}
          </p>
        </div>
        <section aria-labelledby="host-ranking-heading">
          <h2 id="host-ranking-heading" class="text-xl font-semibold tracking-tight">
            Ranking completo
          </h2>
          <div id="host-ranking" class="mt-4 overflow-x-auto rounded-lg border border-border">
            <table class="w-full text-sm">
              <thead class="bg-muted/50">
                <tr class="border-b border-border text-left text-muted-foreground">
                  <th scope="col" class="h-10 px-4 font-medium">Posição</th>
                  <th scope="col" class="h-10 px-4 font-medium">Participante</th>
                  <th scope="col" class="h-10 px-4 font-medium">Acertos</th>
                  <th scope="col" class="h-10 px-4 font-medium">Pontuação</th>
                  <th scope="col" class="h-10 px-4"><span class="sr-only">Detalhes</span></th>
                </tr>
              </thead>
              <tbody class="[&_tr:last-child]:border-0">
                <tr
                  :for={result <- @session.game_results}
                  id={"host-ranking-result-#{result.id}"}
                  class="border-b border-border transition-colors hover:bg-muted/40"
                >
                  <td class="px-4 py-3 font-medium tabular-nums">{result.final_position}º</td>
                  <td class="px-4 py-3 break-words">{result.nickname}</td>
                  <td class="px-4 py-3 whitespace-nowrap">
                    {Formatters.format_correct_answers(result.correct_answers)}
                  </td>
                  <td class="px-4 py-3 whitespace-nowrap tabular-nums">
                    {Formatters.format_score(result.score)}
                  </td>
                  <td class="px-4 py-3 text-right">
                    <.button
                      navigate={~p"/game-history/#{@session.id}/participants/#{result.id}"}
                      variant="ghost"
                      size="sm"
                    >
                      Detalhes
                    </.button>
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
