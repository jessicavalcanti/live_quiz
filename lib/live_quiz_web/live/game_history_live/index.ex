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
        ResultFilters.normalize(params),
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
        <div>
          <p class="text-sm font-semibold uppercase tracking-wider text-primary">Área do host</p>
          <h1 class="mt-2 text-3xl font-bold">Histórico dos quizzes</h1>
          <p class="mt-2 text-base-content/70">
            Consulte partidas finalizadas e o desempenho dos participantes.
          </p>
        </div>
        <.form
          for={%{}}
          as={:filters}
          id="host-game-history-filters"
          phx-submit="filter"
          class="grid gap-4 rounded-box bg-base-200 p-4 sm:grid-cols-4"
        >
          <.input
            name="filters[quiz_id]"
            value={@filters["quiz_id"]}
            label="ID do quiz"
            placeholder="Todos os quizzes"
          />
          <.input name="filters[from]" value={@filters["from"]} type="date" label="De" />
          <.input name="filters[to]" value={@filters["to"]} type="date" label="Até" />
          <button class="btn btn-primary self-end" type="submit" id="apply-host-history-filters">Filtrar</button>
        </.form>
        <div id="host-game-history" class="space-y-3">
          <%= if @page.entries == [] do %>
            <div
              id="host-game-history-empty"
              class="rounded-box border border-dashed border-base-300 p-10 text-center"
            >
              <h2 class="text-xl font-semibold">Nenhuma partida finalizada encontrada.</h2>
            </div>
          <% else %>
            <article
              :for={entry <- @page.entries}
              id={"host-game-history-#{entry.session.id}"}
              class="rounded-box border border-base-300 bg-base-100 p-5 shadow-sm"
            >
              <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
                <div>
                  <h2 class="font-semibold">{entry.quiz_title}</h2>
                  <p class="text-sm text-base-content/60">
                    {Formatters.format_datetime(entry.session.finished_at)}
                  </p>
                  <p class="mt-2 text-sm">
                    {entry.participants_count} participantes · Vencedor: {entry.winner_nickname || "—"}
                  </p>
                </div>
                <div class="flex items-center gap-4">
                  <span class="badge badge-primary">{Formatters.format_score(entry.winner_score || 0)}</span>
                  <.link
                    navigate={~p"/game-history/#{entry.session.id}"}
                    class="btn btn-outline btn-sm"
                  >Ver ranking</.link>
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
          <.link
            :if={@page.page > 1}
            patch={pagination_path(@filters, @page.page - 1)}
            class="btn btn-sm"
          >Anterior</.link>
          <span class="self-center text-sm">Página {@page.page} de {@page.total_pages}</span>
          <.link
            :if={@page.page < @page.total_pages}
            patch={pagination_path(@filters, @page.page + 1)}
            class="btn btn-sm"
          >Próxima</.link>
        </nav>
      </div>
    </Layouts.app>
    """
  end

  defp pagination_path(filters, page), do: ~p"/game-history?#{FilterForm.query(filters, page)}"
end
