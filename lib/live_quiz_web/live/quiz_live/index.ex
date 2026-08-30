defmodule LiveQuizWeb.QuizLive.Index do
  @moduledoc """
  Dashboard listing the quizzes of the authenticated user.

  The URL is the source of truth for what the screen shows: `handle_params/3`
  reads `page` and `search` from it and asks the context for that slice. Typing
  in the search box only pushes a patch, so the address bar always describes the
  current state and the back button works.
  """
  use LiveQuizWeb, :live_view

  alias LiveQuiz.Quizzes
  alias LiveQuizWeb.Formatters

  @per_page 20

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Meus quizzes")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    search = params |> Map.get("search", "") |> to_string()

    page =
      Quizzes.list_quizzes(socket.assigns.current_scope,
        page: Map.get(params, "page"),
        per_page: @per_page,
        search: search
      )

    {:noreply, assign(socket, page: page, search: search)}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    # Back to page 1: the term changed, so the old offset means nothing.
    {:noreply, push_patch(socket, to: ~p"/quizzes?#{query(search, 1)}")}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/quizzes")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Meus quizzes
        <:subtitle>
          {summary(@page)}
        </:subtitle>
        <:actions>
          <.button disabled title="Disponível na próxima entrega">
            Criar quiz
          </.button>
        </:actions>
      </.header>

      <form id="quiz-search" phx-change="search" phx-submit="search" role="search" class="mt-6">
        <label for="quiz-search-input" class="sr-only">Buscar por título</label>

        <div class="flex gap-2">
          <input
            type="text"
            id="quiz-search-input"
            name="search"
            value={@search}
            placeholder="Buscar por título"
            phx-debounce="300"
            autocomplete="off"
            class="input input-bordered w-full"
          />

          <button
            :if={@search != ""}
            type="button"
            phx-click="clear_search"
            class="btn btn-ghost"
          >
            Limpar busca
          </button>
        </div>
      </form>

      <div :if={@page.entries == []} class="mt-10 space-y-4 text-center">
        <p class="text-base-content/70">
          {empty_message(@page, @search)}
        </p>

        <button
          :if={@search != ""}
          type="button"
          phx-click="clear_search"
          class="btn btn-primary btn-soft"
        >
          Limpar busca
        </button>

        <.link
          :if={@search == "" and @page.total_entries > 0}
          patch={~p"/quizzes"}
          class="btn btn-primary btn-soft"
        >
          Voltar para a primeira página
        </.link>

        <div :if={@search == "" and @page.total_entries == 0}>
          <.button disabled title="Disponível na próxima entrega">
            Criar quiz
          </.button>
        </div>
      </div>

      <div :if={@page.entries != []} class="mt-6 overflow-x-auto">
        <table class="table">
          <thead>
            <tr>
              <th scope="col">Título</th>
              <th scope="col" class="hidden md:table-cell">Descrição</th>
              <th scope="col">Perguntas</th>
              <th scope="col" class="hidden sm:table-cell">Criado em</th>
              <th scope="col">Situação</th>
              <th scope="col"><span class="sr-only">Ações</span></th>
            </tr>
          </thead>

          <tbody id="quizzes">
            <tr :for={quiz <- @page.entries} id={"quiz-#{quiz.id}"}>
              <td class="font-medium">{quiz.title}</td>
              <td class="hidden md:table-cell text-base-content/70">
                {description(quiz)}
              </td>
              <td>{question_count(quiz)}</td>
              <td class="hidden sm:table-cell whitespace-nowrap">
                {Formatters.format_date(quiz.inserted_at)}
              </td>
              <td>
                <span class={["badge", status_class(quiz)]}>{status(quiz)}</span>
              </td>
              <td class="w-0">
                <span class="text-base-content/40" title="Disponível na próxima entrega">
                  Editar
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <nav
        :if={@page.total_pages > 1}
        aria-label="Paginação"
        class="mt-6 flex items-center justify-between gap-4"
      >
        <.link
          :if={@page.page > 1}
          patch={~p"/quizzes?#{query(@search, @page.page - 1)}"}
          class="btn btn-soft btn-sm"
        >
          Anterior
        </.link>
        <span :if={@page.page <= 1} class="btn btn-soft btn-sm btn-disabled" aria-hidden="true">
          Anterior
        </span>

        <span class="text-sm text-base-content/70">
          Página {@page.page} de {@page.total_pages}
        </span>

        <.link
          :if={@page.page < @page.total_pages}
          patch={~p"/quizzes?#{query(@search, @page.page + 1)}"}
          class="btn btn-soft btn-sm"
        >
          Próxima
        </.link>
        <span
          :if={@page.page >= @page.total_pages}
          class="btn btn-soft btn-sm btn-disabled"
          aria-hidden="true"
        >
          Próxima
        </span>
      </nav>
    </Layouts.app>
    """
  end

  defp query(search, page) do
    search = String.trim(to_string(search))

    []
    |> put_param(:search, search != "", search)
    |> put_param(:page, page > 1, page)
  end

  defp put_param(params, _key, false, _value), do: params
  defp put_param(params, key, true, value), do: params ++ [{key, value}]

  defp summary(%{total_entries: 0}), do: "Você ainda não tem quizzes por aqui."
  defp summary(%{total_entries: 1}), do: "1 quiz."
  defp summary(%{total_entries: total}), do: "#{total} quizzes."

  defp empty_message(_page, search) when search != "",
    do: ~s(Nenhum quiz encontrado para "#{search}".)

  # The user does have quizzes, just none this far into the list.
  defp empty_message(%{total_entries: total}, _search) when total > 0,
    do: "Esta página não tem quizzes."

  defp empty_message(_page, _search), do: "Você ainda não criou nenhum quiz."

  defp description(%{description: nil}), do: "—"
  defp description(%{description: ""}), do: "—"
  defp description(%{description: description}), do: description

  defp question_count(%{questions_count: 0}), do: "Nenhuma pergunta"
  defp question_count(%{questions_count: 1}), do: "1 pergunta"
  defp question_count(%{questions_count: count}), do: "#{count} perguntas"

  defp status(quiz) do
    if Quizzes.playable?(quiz), do: "Pronto para jogar", else: "Incompleto"
  end

  defp status_class(quiz) do
    if Quizzes.playable?(quiz), do: "badge-success", else: "badge-ghost"
  end
end
