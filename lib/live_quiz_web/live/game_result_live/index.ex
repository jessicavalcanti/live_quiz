defmodule LiveQuizWeb.GameResultLive.Index do
  @moduledoc "Authenticated list of the current user's finished matches."

  use LiveQuizWeb, :live_view

  alias LiveQuiz.Games
  alias LiveQuizWeb.Formatters

  @per_page 10

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket, page_title: "Minhas partidas", filters: %{quiz_id: "", from: "", to: ""})}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters =
      params
      |> Map.take(["quiz_id", "from", "to"])
      |> clean_filters()

    page =
      Games.list_game_results(socket.assigns.current_scope, context_filters(filters), %{
        page: params["page"],
        per_page: @per_page
      })

    {:noreply,
     assign(socket,
       page: page,
       filters: Map.merge(%{"quiz_id" => "", "from" => "", "to" => ""}, filters)
     )}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    filters = for {key, value} <- filters, value != "", into: %{}, do: {key, value}
    {:noreply, push_patch(socket, to: ~p"/game-results?#{query(filters)}")}
  end

  defp query(filters), do: Map.put(filters, "page", 1)

  defp clean_filters(filters), do: Map.reject(filters, fn {_key, value} -> value == "" end)

  defp context_filters(filters) do
    filters
    |> maybe_expand_date("from", "T00:00:00Z")
    |> maybe_expand_date("to", "T23:59:59Z")
  end

  defp maybe_expand_date(filters, key, suffix) do
    case Map.get(filters, key) do
      <<year::binary-size(4), "-", month::binary-size(2), "-", day::binary-size(2)>> ->
        Map.put(filters, key, year <> "-" <> month <> "-" <> day <> suffix)

      _value ->
        filters
    end
  end

  defp pagination_path(params, page) do
    ~p"/game-results?#{params |> clean_filters() |> Map.put("page", page)}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-8" id="game-results-page">
        <div>
          <p class="text-sm font-semibold uppercase tracking-wider text-primary">Seu histórico</p>
          <h1 class="mt-2 text-3xl font-bold">Minhas partidas</h1>
          <p class="mt-2 text-base-content/70">Acompanhe seus resultados e evolução.</p>
        </div>

        <.form
          for={%{}}
          as={:filters}
          id="game-results-filters"
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
          <button class="btn btn-primary self-end" type="submit" id="apply-result-filters">Filtrar</button>
        </.form>

        <div id="game-results" class="space-y-3">
          <%= if @page.entries == [] do %>
            <div
              id="game-results-empty"
              class="rounded-box border border-dashed border-base-300 p-10 text-center"
            >
              <h2 class="text-xl font-semibold">Você ainda não tem partidas finalizadas.</h2>
              <p class="mt-2 text-base-content/70">Seus próximos resultados aparecerão aqui.</p>
            </div>
          <% else %>
            <div
              :for={result <- @page.entries}
              id={"game-result-#{result.id}"}
              class="flex flex-col gap-4 rounded-box border border-base-300 bg-base-100 p-5 shadow-sm sm:flex-row sm:items-center sm:justify-between"
            >
              <div>
                <h2 class="font-semibold">{result.quiz_title}</h2>
                <p class="text-sm text-base-content/60">
                  {Formatters.format_datetime(result.inserted_at)}
                </p>
                <p class="mt-2 text-sm">
                  {Formatters.format_score(result.score)} · {Formatters.format_correct_answers(
                    result.correct_answers
                  )}
                </p>
              </div>
              <div class="flex items-center gap-4">
                <span class="badge badge-primary">#{result.final_position} lugar</span>
                <.link navigate={~p"/game-results/#{result.id}"} class="btn btn-outline btn-sm">Ver detalhes</.link>
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
end
