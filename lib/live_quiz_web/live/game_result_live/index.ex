defmodule LiveQuizWeb.GameResultLive.Index do
  @moduledoc "Authenticated list of the current user's finished matches."

  use LiveQuizWeb, :live_view

  alias LiveQuiz.Games
  alias LiveQuiz.Games.ResultFilters
  alias LiveQuizWeb.FilterForm
  alias LiveQuizWeb.Formatters

  @per_page 10

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Minhas partidas", filters: FilterForm.from_params(%{}))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # O resumo, e não a linha inteira: esta tela mostra seis campos, e o
    # detalhe de cada pergunta de cada partida ficaria no socket enquanto a
    # aba estivesse aberta (R37).
    page =
      Games.list_game_result_summaries(
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
    {:noreply, push_patch(socket, to: ~p"/game-results?#{FilterForm.query(filters, 1)}")}
  end

  # The podium reads at a glance; fourth place onwards is a fact, not a
  # highlight.
  defp position_variant(position) when position <= 3, do: "default"
  defp position_variant(_position), do: "secondary"

  defp pagination_path(filters, page), do: ~p"/game-results?#{FilterForm.query(filters, page)}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-8" id="game-results-page">
        <.back_button
          id="back-to-quizzes"
          navigate={~p"/quizzes"}
          label="Voltar para Meus quizzes"
        />

        <div>
          <p class="text-sm font-medium tracking-wider text-muted-foreground uppercase">
            Seu histórico
          </p>
          <h1 class="mt-2 text-3xl font-semibold tracking-tight">Minhas partidas</h1>
          <p class="mt-2 text-muted-foreground">Acompanhe seus resultados e evolução.</p>
        </div>

        <.form
          for={%{}}
          as={:filters}
          id="game-results-filters"
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
          <.button type="submit" id="apply-result-filters" class="mb-4">Filtrar</.button>
        </.form>

        <div id="game-results" class="space-y-3">
          <%= if @page.entries == [] do %>
            <div
              id="game-results-empty"
              class="rounded-lg border border-dashed border-border p-10 text-center"
            >
              <h2 class="text-lg font-semibold tracking-tight">
                Você ainda não tem partidas finalizadas.
              </h2>
              <p class="mt-2 text-sm text-muted-foreground">
                Seus próximos resultados aparecerão aqui.
              </p>
            </div>
          <% else %>
            <div
              :for={result <- @page.entries}
              id={"game-result-#{result.id}"}
              class="flex flex-col gap-4 rounded-lg border border-border bg-card p-5 transition-colors hover:border-ring/40 sm:flex-row sm:items-center sm:justify-between"
            >
              <div>
                <h2 class="font-medium">{result.quiz_title}</h2>
                <p class="text-sm text-muted-foreground">
                  {Formatters.format_datetime(result.inserted_at)}
                </p>
                <p class="mt-2 text-sm text-muted-foreground">
                  {Formatters.format_score(result.score)} · {Formatters.format_correct_answers(
                    result.correct_answers
                  )}
                </p>
              </div>
              <div class="flex items-center gap-3">
                <%!--
                  The podium is the one number worth colour on this row, so the
                  top three carry the solid badge and everything below it stays
                  neutral.
                --%>
                <.badge variant={position_variant(result.final_position)} class="whitespace-nowrap">
                  #{result.final_position} lugar
                </.badge>
                <.button navigate={~p"/game-results/#{result.id}"} variant="outline" size="sm">
                  Ver detalhes
                </.button>
              </div>
            </div>
          <% end %>
        </div>

        <nav
          :if={@page.total_pages > 1}
          id="game-results-pagination"
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
end
