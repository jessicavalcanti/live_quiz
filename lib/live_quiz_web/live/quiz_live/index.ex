defmodule LiveQuizWeb.QuizLive.Index do
  @moduledoc """
  Dashboard listing the quizzes of the authenticated user.

  The URL is the source of truth for what the screen shows: `handle_params/3`
  reads `page` and `search` from it and asks the context for that slice. Typing
  in the search box only pushes a patch, so the address bar always describes the
  current state and the back button works.

  "Iniciar partida" is the one action here that asks something before doing it:
  since F3-07 the host chooses how long each question lasts, and the choice is
  made where the room is opened rather than when the match starts (AD-38), with
  a room full of people waiting. The modal restates none of the rules — the
  options come from `LiveQuiz.Games.GameSession.question_durations/0` and a
  refused submission is rendered from the changeset the context hands back.
  """
  use LiveQuizWeb, :live_view

  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
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
     |> assign(:quiz_to_start, nil)
     |> assign(:session_form, nil)
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

  def handle_event("start_game", %{"id" => id}, socket) do
    quiz = Quizzes.get_quiz!(socket.assigns.current_scope, id)

    {:noreply,
     socket
     |> assign(:quiz_to_start, quiz)
     |> assign_session_form(Games.change_question_duration())}
  end

  def handle_event("cancel_start", _params, socket) do
    {:noreply, close_start_modal(socket)}
  end

  # The screen decides nothing about the duration: it sends what was marked and
  # renders whatever the context answers. A room that already exists is not a
  # refusal to read — it is the room the host is looking for.
  def handle_event("create_session", %{"game_session" => params}, socket) do
    %{current_scope: scope, quiz_to_start: quiz} = socket.assigns

    case Games.create_game_session(scope, quiz.id, params) do
      {:ok, session} ->
        {:noreply, push_navigate(socket, to: ~p"/game-sessions/#{session.join_code}/host")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_session_form(socket, Map.put(changeset, :action, :insert))}

      {:error, :host_already_in_session} ->
        {:noreply, resume_active_session(socket)}

      {:error, reason} ->
        {:noreply,
         socket
         |> close_start_modal()
         |> put_flash(:error, session_refusal(reason))}
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

  defp assign_session_form(socket, changeset) do
    assign(socket, :session_form, to_form(changeset, as: :game_session))
  end

  defp close_start_modal(socket) do
    socket
    |> assign(:quiz_to_start, nil)
    |> assign(:session_form, nil)
  end

  # The room may have been closed between the refusal and this read, in which
  # case there is nowhere to send the host and the reason has to be read on the
  # dashboard itself.
  defp resume_active_session(socket) do
    socket = close_start_modal(socket)

    case Games.get_active_session_for_host(socket.assigns.current_scope) do
      nil ->
        put_flash(socket, :error, session_refusal(:host_already_in_session))

      session ->
        socket
        |> put_flash(:info, "Você já tem uma sala aberta. Continue por ela.")
        |> push_navigate(to: ~p"/game-sessions/#{session.join_code}/host")
    end
  end

  defp session_refusal(:quiz_not_playable),
    do: "Adicione ao menos uma pergunta antes de iniciar uma partida"

  defp session_refusal(:already_participating),
    do: "Saia da sala em que você está antes de abrir a sua"

  defp session_refusal(:host_already_in_session), do: "Você já tem uma sala aberta"

  defp session_refusal(_reason), do: "Não foi possível abrir a sala. Tente novamente."

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
        class="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-info/40 bg-info/10 p-4 text-sm"
      >
        <p>
          Você tem uma sala aberta para
          <strong class="font-medium">{@active_session.quiz_title}</strong>
          com o código <strong class="rounded bg-background px-1.5 py-0.5 font-mono tracking-wider">
            {@active_session.join_code}
          </strong>.
        </p>

        <.button navigate={~p"/game-sessions/#{@active_session.join_code}/host"} size="sm">
          Voltar para a sala
        </.button>
      </div>

      <form id="quiz-search" phx-change="search" phx-submit="search" role="search">
        <label for="quiz-search-input" class="sr-only">Buscar por título</label>

        <div class="flex gap-2">
          <div class="relative flex-1">
            <.icon
              name="hero-magnifying-glass"
              class="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-muted-foreground"
            />
            <input
              type="text"
              id="quiz-search-input"
              name="search"
              value={@search}
              placeholder="Buscar por título"
              phx-debounce="300"
              autocomplete="off"
              class="flex h-10 w-full rounded-md border border-input bg-background pr-3 pl-9 text-sm placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/50 focus-visible:outline-hidden"
            />
          </div>

          <.button :if={@search != ""} type="button" phx-click="clear_search" variant="ghost">
            Limpar busca
          </.button>
        </div>
      </form>

      <div
        :if={@page.entries == []}
        class="flex flex-col items-center gap-4 rounded-lg border border-dashed border-border px-6 py-14 text-center"
      >
        <span class="flex size-10 items-center justify-center rounded-full bg-muted">
          <.icon name="hero-rectangle-stack" class="size-5 text-muted-foreground" />
        </span>

        <p class="text-sm text-muted-foreground">
          {empty_message(@page, @search)}
        </p>

        <.button :if={@search != ""} type="button" phx-click="clear_search" variant="secondary">
          Limpar busca
        </.button>

        <.button
          :if={@search == "" and @page.total_entries > 0}
          patch={~p"/quizzes"}
          variant="secondary"
        >
          Voltar para a primeira página
        </.button>

        <.button
          :if={@search == "" and @page.total_entries == 0}
          id="first-quiz-button"
          patch={~p"/quizzes/new"}
          phx-click={JS.push_focus()}
        >
          Criar quiz
        </.button>
      </div>

      <div
        :if={@page.entries != []}
        id="quiz-list"
        class="overflow-hidden rounded-lg border border-border"
      >
        <table class="w-full text-sm">
          <thead class="bg-muted/50">
            <tr class="border-b border-border text-left text-muted-foreground">
              <th scope="col" class="h-10 px-4 font-medium">Título</th>
              <th scope="col" class="hidden h-10 px-4 font-medium lg:table-cell">Descrição</th>
              <th scope="col" class="hidden h-10 px-4 font-medium sm:table-cell">Perguntas</th>
              <th scope="col" class="hidden h-10 px-4 font-medium xl:table-cell">Criado em</th>
              <th scope="col" class="hidden h-10 px-4 font-medium md:table-cell">Situação</th>
              <th scope="col" class="h-10 px-4"><span class="sr-only">Ações</span></th>
            </tr>
          </thead>

          <tbody id="quizzes" class="[&_tr:last-child]:border-0">
            <tr
              :for={quiz <- @page.entries}
              id={"quiz-#{quiz.id}"}
              class="border-b border-border transition-colors hover:bg-muted/40"
            >
              <td class="min-w-0 px-4 py-3 align-top font-medium">
                <span class="break-words">{quiz.title}</span>
                <p class="mt-1 break-words text-sm font-normal text-muted-foreground lg:hidden">
                  {description(quiz)}
                </p>
                <div class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 font-normal">
                  <span class="text-xs text-muted-foreground sm:hidden">{question_count(quiz)}</span>
                  <span class="text-xs text-muted-foreground xl:hidden">
                    {Formatters.format_date(quiz.inserted_at)}
                  </span>
                  <.badge variant={status_variant(quiz)} class="whitespace-nowrap md:hidden">
                    {status(quiz)}
                  </.badge>
                </div>
              </td>
              <td class="hidden break-words px-4 py-3 align-top text-muted-foreground lg:table-cell">
                {description(quiz)}
              </td>
              <td class="hidden px-4 py-3 align-top whitespace-nowrap sm:table-cell">
                {question_count(quiz)}
              </td>
              <td class="hidden px-4 py-3 align-top whitespace-nowrap xl:table-cell">
                {Formatters.format_date(quiz.inserted_at)}
              </td>
              <td class="hidden px-4 py-3 align-top md:table-cell">
                <.badge variant={status_variant(quiz)} class="whitespace-nowrap">
                  {status(quiz)}
                </.badge>
              </td>
              <td class="w-0 px-4 py-3 align-top">
                <div class="flex flex-col items-end gap-1">
                  <div class="flex min-w-max items-center gap-2">
                    <.button
                      type="button"
                      size="icon"
                      class="size-8"
                      id={"start-game-button-#{quiz.id}"}
                      disabled={not startable?(quiz)}
                      aria-disabled={to_string(not startable?(quiz))}
                      aria-describedby={hint_target(quiz)}
                      aria-label="Iniciar partida"
                      title="Iniciar partida"
                      phx-click={JS.push_focus() |> JS.push("start_game", value: %{id: quiz.id})}
                    >
                      <.icon name="hero-play" class="size-4" />
                      <span class="sr-only">Iniciar partida</span>
                    </.button>

                    <.button
                      :if={not quiz.locked?}
                      navigate={~p"/quizzes/#{quiz}/edit"}
                      variant="ghost"
                      size="icon"
                      class="size-8"
                      aria-label="Editar quiz"
                      title="Editar quiz"
                    >
                      <.icon name="hero-pencil-square" class="size-4" />
                      <span class="sr-only">Editar</span>
                    </.button>

                    <.button
                      :if={quiz.locked?}
                      type="button"
                      variant="ghost"
                      size="icon"
                      class="size-8"
                      id={"edit-quiz-#{quiz.id}"}
                      disabled
                      aria-disabled="true"
                      aria-describedby={hint_target(quiz)}
                      aria-label="Editar quiz"
                      title="Editar quiz"
                    >
                      <.icon name="hero-pencil-square" class="size-4" />
                      <span class="sr-only">Editar</span>
                    </.button>

                    <.button
                      type="button"
                      variant="ghost"
                      size="icon"
                      class="size-8 text-destructive hover:bg-destructive/10 hover:text-destructive"
                      id={"delete-quiz-#{quiz.id}"}
                      disabled={quiz.locked?}
                      aria-disabled={to_string(quiz.locked?)}
                      aria-describedby={hint_target(quiz)}
                      aria-label="Excluir quiz"
                      title="Excluir quiz"
                      phx-click={JS.push_focus() |> JS.push("delete_quiz", value: %{id: quiz.id})}
                    >
                      <.icon name="hero-trash" class="size-4" />
                      <span class="sr-only">Excluir</span>
                    </.button>
                  </div>

                  <p
                    :if={hint(quiz)}
                    id={"quiz-hint-#{quiz.id}"}
                    class="max-w-48 text-right text-xs whitespace-normal text-warning-strong"
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
        class="flex items-center justify-between gap-4"
      >
        <%!--
          The edge of the list renders a disabled button rather than dropping the
          control, so the row keeps its shape and the page number stays put
          between the first page and the last.
        --%>
        <.button
          :if={@page.page > 1}
          patch={~p"/quizzes?#{query(@search, @page.page - 1)}"}
          variant="outline"
          size="sm"
        >
          Anterior
        </.button>
        <.button :if={@page.page <= 1} variant="outline" size="sm" disabled aria-hidden="true">
          Anterior
        </.button>

        <span class="text-sm text-muted-foreground">
          Página {@page.page} de {@page.total_pages}
        </span>

        <.button
          :if={@page.page < @page.total_pages}
          patch={~p"/quizzes?#{query(@search, @page.page + 1)}"}
          variant="outline"
          size="sm"
        >
          Próxima
        </.button>
        <.button
          :if={@page.page >= @page.total_pages}
          variant="outline"
          size="sm"
          disabled
          aria-hidden="true"
        >
          Próxima
        </.button>
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

          <div class="mt-6 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
            <.button patch={~p"/quizzes"} phx-click={JS.pop_focus()} variant="ghost">
              Cancelar
            </.button>

            <.button phx-disable-with="Salvando...">
              Criar quiz
            </.button>
          </div>
        </.form>
      </.modal>

      <.modal
        :if={@quiz_to_start}
        id="start-game"
        title={~s(Iniciar partida de "#{@quiz_to_start.title}")}
        on_cancel={JS.push("cancel_start") |> JS.pop_focus()}
      >
        <.form for={@session_form} id="start-game-form" phx-submit="create_session">
          <.input
            field={@session_form[:question_duration_seconds]}
            type="radio-group"
            label="Tempo por pergunta"
            options={Enum.map(GameSession.question_durations(), &{"#{&1} segundos", &1})}
          />

          <p class="mt-2 text-sm text-muted-foreground">
            O tempo vale para todas as perguntas e não pode ser alterado depois que a
            sala é aberta.
          </p>

          <div class="mt-6 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
            <.button
              type="button"
              phx-click={JS.push("cancel_start") |> JS.pop_focus()}
              variant="ghost"
            >
              Cancelar
            </.button>

            <.button phx-disable-with="Abrindo...">
              Abrir sala
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
        <p class="text-muted-foreground">{deletion_impact(@quiz_to_delete)}</p>

        <:actions>
          <.button
            type="button"
            phx-click={JS.push("cancel_delete") |> JS.pop_focus()}
            variant="ghost"
          >
            Cancelar
          </.button>

          <.button
            type="button"
            phx-click="confirm_delete"
            phx-disable-with="Excluindo..."
            variant="destructive"
          >
            Excluir quiz
          </.button>
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

  defp status_variant(quiz) do
    if Quizzes.playable?(quiz), do: "success", else: "secondary"
  end
end
