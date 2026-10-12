defmodule LiveQuizWeb.GameHistoryLive.Index do
  @moduledoc "Host history of finished matches from the user's quizzes."

  use LiveQuizWeb, :live_view

  alias LiveQuiz.Games
  alias LiveQuiz.Games.ResultFilters
  alias LiveQuizWeb.FilterForm
  alias LiveQuizWeb.Formatters

  @per_page 10

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket, page_title: "Histórico dos quizzes", filters: FilterForm.from_params(%{}))}

  @impl true
  def handle_params(params, _uri, socket) do
    page =
      Games.list_host_game_history(
        socket.assigns.current_scope,
        # O dia que a tela mostra é o de São Paulo, e é nesse fuso que ela tem
        # de ser lida — senão a partida que aparece no dia 6 fica de fora quando
        # se filtra o dia 6 (R39).
        ResultFilters.normalize(params, time_zone: ResultFilters.screen_time_zone()),
        %{page: params["page"], per_page: @per_page}
      )

    {:noreply, assign(socket, page: page, filters: FilterForm.from_params(params))}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: ~p"/game-history?#{FilterForm.query(filters, 1)}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="host-game-history-page" class="space-y-8">
        <.back_button
          id="back-to-quizzes"
          navigate={~p"/quizzes"}
          label="Voltar para Meus quizzes"
        />

        <div>
          <p class="text-sm font-medium tracking-wider text-muted-foreground uppercase">
            Área do host
          </p>
          <h1 class="mt-2 text-3xl font-semibold tracking-tight">Histórico dos quizzes</h1>
          <p class="mt-2 text-muted-foreground">
            Consulte partidas finalizadas e o desempenho dos participantes.
          </p>
        </div>
        <.form
          for={%{}}
          as={:filters}
          id="host-game-history-filters"
          phx-submit="filter"
          class="grid items-end gap-4 rounded-lg border border-border bg-muted/40 p-4 sm:grid-cols-4"
        >
          <.input
            name="filters[quiz_id]"
            value={@filters["quiz_id"]}
            label="ID do quiz"
            placeholder="Todos os quizzes"
          />
          <.input name="filters[from]" value={@filters["from"]} type="date" label="De" />
          <.input name="filters[to]" value={@filters["to"]} type="date" label="Até" />
          <.button type="submit" id="apply-host-history-filters" class="mb-4">Filtrar</.button>
        </.form>
        <div id="host-game-history" class="space-y-3">
          <%= if @page.entries == [] do %>
            <div
              id="host-game-history-empty"
              class="rounded-lg border border-dashed border-border p-10 text-center"
            >
              <h2 class="text-lg font-semibold tracking-tight">
                Nenhuma partida finalizada encontrada.
              </h2>
            </div>
          <% else %>
            <article
              :for={entry <- @page.entries}
              id={"host-game-history-#{entry.session.id}"}
              class="rounded-lg border border-border bg-card p-5 transition-colors hover:border-ring/40"
            >
              <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
                <div>
                  <h2 class="font-medium">{entry.quiz_title}</h2>
                  <p class="text-sm text-muted-foreground">
                    {Formatters.format_datetime(entry.session.finished_at)}
                  </p>
                  <p class="mt-2 text-sm text-muted-foreground">
                    {entry.participants_count} participantes · Vencedor: {entry.winner_nickname || "—"}
                  </p>
                </div>
                <div class="flex items-center gap-3">
                  <.badge variant="secondary" class="tabular-nums">
                    {Formatters.format_score(entry.winner_score || 0)}
                  </.badge>
                  <.button
                    navigate={~p"/game-history/#{entry.session.id}"}
                    variant="outline"
                    size="sm"
                  >
                    Ver ranking
                  </.button>
                </div>
              </div>
            </article>
          <% end %>
        </div>
        <nav
          :if={@page.total_pages > 1}
          id="host-game-history-pagination"
          class="flex justify-center gap-2"
          aria-label="Paginação"
        >
          <.button
            :if={@page.page > 1}
            patch={pagination_path(@filters, @page.page - 1)}
            variant="outline"
            size="sm"
          >
            Anterior
          </.button>
          <span class="self-center text-sm text-muted-foreground">
            Página {@page.page} de {@page.total_pages}
          </span>
          <.button
            :if={@page.page < @page.total_pages}
            patch={pagination_path(@filters, @page.page + 1)}
            variant="outline"
            size="sm"
          >
            Próxima
          </.button>
        </nav>
      </div>
    </Layouts.app>
    """
  end

  defp pagination_path(filters, page), do: ~p"/game-history?#{FilterForm.query(filters, page)}"
end
