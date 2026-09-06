defmodule LiveQuizWeb.QuizLive.Index do
  @moduledoc """
  Dashboard listing the quizzes of the authenticated user.

  The URL is the source of truth for what the screen shows: `handle_params/3`
  reads `page` and `search` from it and asks the context for that slice. Typing
  in the search box only pushes a patch, so the address bar always describes the
  current state and the back button works.
  """
  use LiveQuizWeb, :live_view

  alias LiveQuiz.Games
  alias LiveQuiz.Quizzes
  alias LiveQuiz.Quizzes.Quiz
  alias LiveQuizWeb.Formatters
  alias Phoenix.LiveView.JS

  @per_page 20

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Meus quizzes")
     |> assign(:quiz_to_delete, nil)
     |> assign(:invalid_field, nil)
     |> assign(:attempt, 0)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    search = params |> Map.get("search", "") |> to_string()

    scope = socket.assigns.current_scope
    page = list_quizzes(scope, search, Map.get(params, "page"))

    {:noreply,
     socket
     |> assign(page: page, search: search)
     |> assign(:active_session, Games.get_active_session_for_host(scope))
     |> apply_action(socket.assigns.live_action)}
  end

  defp apply_action(socket, :new) do
    socket
    |> assign(:page_title, "Criar quiz")
    |> assign(:invalid_field, nil)
    |> assign_form(Quizzes.change_quiz(%Quiz{}))
  end

  defp apply_action(socket, :index) do
    assign(socket, :page_title, "Meus quizzes")
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    # Back to page 1: the term changed, so the old offset means nothing.
    {:noreply, push_patch(socket, to: ~p"/quizzes?#{query(search, 1)}")}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/quizzes")}
  end

  def handle_event("validate_quiz", %{"quiz" => quiz_params}, socket) do
    changeset = Quizzes.change_quiz(%Quiz{}, quiz_params)

    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save_quiz", %{"quiz" => quiz_params}, socket) do
    case Quizzes.create_quiz(socket.assigns.current_scope, quiz_params) do
      {:ok, quiz} ->
        {:noreply,
         socket
         |> put_flash(:info, "Quiz criado com sucesso")
         |> push_navigate(to: ~p"/quizzes/#{quiz}/edit")}

      {:error, changeset} ->
        {:noreply, refuse_save(socket, changeset)}
    end
  end

  def handle_event("delete_quiz", %{"id" => id}, socket) do
    quiz = Quizzes.get_quiz!(socket.assigns.current_scope, id)

    {:noreply, assign(socket, :quiz_to_delete, quiz)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :quiz_to_delete, nil)}
  end

  def handle_event("confirm_delete", _params, socket) do
    %{current_scope: scope, quiz_to_delete: quiz, search: search, page: page} = socket.assigns

    socket =
      case Quizzes.delete_quiz(scope, quiz) do
        {:ok, _deleted} -> put_flash(socket, :info, "Quiz excluído")
        {:error, :quiz_locked} -> put_flash(socket, :error, locked_message())
      end

    socket = assign(socket, :quiz_to_delete, nil)

    {:noreply, refresh_after_delete(socket, scope, search, page.page)}
  end

  # Staying on a page that no longer exists would show an empty list, so the
  # user goes back to the first one.
  defp refresh_after_delete(socket, scope, search, page_number) do
    page = list_quizzes(scope, search, page_number)

    if page.entries == [] and page.total_entries > 0 do
      push_patch(socket, to: ~p"/quizzes?#{query(search, 1)}")
    else
      assign(socket, :page, page)
    end
  end

  defp list_quizzes(scope, search, page) do
    Quizzes.list_quizzes(scope, page: page, per_page: @per_page, search: search)
  end

  defp refuse_save(socket, changeset) do
    socket
    |> assign_form(Map.put(changeset, :action, :insert))
    |> assign(:invalid_field, first_invalid_field(changeset))
    |> update(:attempt, &(&1 + 1))
  end

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset, as: :quiz))
  end

  defp first_invalid_field(changeset) do
    Enum.find_value([:title, :description], fn field ->
      if Keyword.has_key?(changeset.errors, field), do: "quiz_#{field}"
    end)
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
          <.button
            id="new-quiz-button"
            variant="primary"
            patch={~p"/quizzes/new"}
            phx-click={JS.push_focus()}
          >
            Criar quiz
          </.button>
        </:actions>
      </.header>

      <div
        :if={@active_session}
        id="active-session-notice"
        role="status"
        class="mt-6 flex flex-wrap items-center justify-between gap-3 rounded-lg border border-info bg-info/10 p-4"
      >
        <p>
          Você tem uma sala aberta para <strong>{@active_session.quiz_title}</strong>
          com o código <strong class="font-mono">{@active_session.join_code}</strong>.
        </p>

        <.link
          navigate={~p"/game-sessions/#{@active_session.join_code}/host"}
          class="btn btn-primary btn-sm"
        >
          Voltar para a sala
        </.link>
      </div>

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
          <.button
            id="first-quiz-button"
            variant="primary"
            patch={~p"/quizzes/new"}
            phx-click={JS.push_focus()}
          >
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
                <div class="flex flex-col items-end gap-1">
                  <div class="flex items-center gap-2">
                    <.form
                      for={%{}}
                      action={~p"/game-sessions"}
                      method="post"
                      id={"start-game-#{quiz.id}"}
                      class="contents"
                    >
                      <input type="hidden" name="quiz_id" value={quiz.id} />

                      <button
                        type="submit"
                        id={"start-game-button-#{quiz.id}"}
                        disabled={not startable?(quiz)}
                        aria-disabled={to_string(not startable?(quiz))}
                        aria-describedby={hint_target(quiz)}
                        class={["btn btn-primary btn-sm", not startable?(quiz) && "btn-disabled"]}
                      >
                        Iniciar partida
                      </button>
                    </.form>

                    <.link
                      :if={not quiz.locked?}
                      navigate={~p"/quizzes/#{quiz}/edit"}
                      class="btn btn-ghost btn-sm"
                    >
                      Editar
                    </.link>

                    <button
                      :if={quiz.locked?}
                      type="button"
                      id={"edit-quiz-#{quiz.id}"}
                      disabled
                      aria-disabled="true"
                      aria-describedby={hint_target(quiz)}
                      class="btn btn-ghost btn-sm btn-disabled"
                    >
                      Editar
                    </button>

                    <button
                      type="button"
                      id={"delete-quiz-#{quiz.id}"}
                      disabled={quiz.locked?}
                      aria-disabled={to_string(quiz.locked?)}
                      aria-describedby={hint_target(quiz)}
                      phx-click={JS.push_focus() |> JS.push("delete_quiz", value: %{id: quiz.id})}
                      class={["btn btn-ghost btn-sm text-error", quiz.locked? && "btn-disabled"]}
                    >
                      Excluir
                    </button>
                  </div>

                  <p
                    :if={hint(quiz)}
                    id={"quiz-hint-#{quiz.id}"}
                    class="text-xs whitespace-normal text-warning"
                  >
                    {hint(quiz)}
                  </p>
                </div>
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

      <.modal
        :if={@live_action == :new}
        id="new-quiz"
        title="Criar quiz"
        on_cancel={JS.patch(~p"/quizzes") |> JS.pop_focus()}
      >
        <.focus_on_error target={@invalid_field} token={@attempt} />

        <.form
          for={@form}
          id="new-quiz-form"
          phx-change="validate_quiz"
          phx-submit="save_quiz"
        >
          <.input field={@form[:title]} type="text" label="Título" required />

          <.input
            field={@form[:description]}
            type="textarea"
            label="Descrição (opcional)"
            rows="3"
          />

          <div class="modal-action">
            <.link patch={~p"/quizzes"} phx-click={JS.pop_focus()} class="btn btn-ghost">
              Cancelar
            </.link>

            <.button variant="primary" phx-disable-with="Salvando...">
              Criar quiz
            </.button>
          </div>
        </.form>
      </.modal>

      <.modal
        :if={@quiz_to_delete}
        id="delete-quiz"
        title={~s(Excluir o quiz "#{@quiz_to_delete.title}"?)}
        on_cancel={JS.push("cancel_delete") |> JS.pop_focus()}
      >
        <p class="text-base-content/70">{deletion_impact(@quiz_to_delete)}</p>

        <:actions>
          <button
            type="button"
            phx-click={JS.push("cancel_delete") |> JS.pop_focus()}
            class="btn btn-ghost"
          >
            Cancelar
          </button>

          <button
            type="button"
            phx-click="confirm_delete"
            phx-disable-with="Excluindo..."
            class="btn btn-error"
          >
            Excluir quiz
          </button>
        </:actions>
      </.modal>
    </Layouts.app>
    """
  end

  # Opening a room takes a quiz with at least one question and no room already
  # running on it. Both refusals are written next to the button instead of being
  # discovered on the click.
  defp startable?(quiz), do: Quizzes.playable?(quiz) and not quiz.locked?

  defp hint(%{locked?: true}), do: locked_hint()

  defp hint(quiz) do
    unless Quizzes.playable?(quiz) do
      "Adicione ao menos uma pergunta para iniciar uma partida"
    end
  end

  defp hint_target(quiz), do: if(hint(quiz), do: "quiz-hint-#{quiz.id}")

  defp deletion_impact(%{questions_count: 0}), do: "Esta ação não pode ser desfeita."

  defp deletion_impact(%{questions_count: 1}),
    do: "Esta ação também removerá 1 pergunta e não pode ser desfeita."

  defp deletion_impact(%{questions_count: count}),
    do: "Esta ação também removerá #{count} perguntas e não pode ser desfeita."

  defp locked_message, do: "Este quiz possui uma sala ativa e não pode ser alterado"

  defp locked_hint, do: "Este quiz possui uma sala ativa"

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
