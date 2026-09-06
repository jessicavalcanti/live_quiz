defmodule LiveQuizWeb.QuizLive.Editor do
  @moduledoc """
  Editor of a single quiz: its title and description, and the list of its
  questions.

  The quiz is loaded through the context with the caller scope, so a quiz that
  belongs to somebody else raises `Ecto.NoResultsError` and the request ends as
  a 404 — the same answer a quiz that never existed would get.

  Adding and editing a question happen in modals with routes of their own, so
  the address bar keeps describing the screen and the back button works. Each
  question is saved on its own: there is no "save everything" button, and the
  list is read back from the context after every write instead of being patched
  in memory.

  Reordering follows the same rule: the arrows ask the context to move the
  question and the list is read back from the database, so the server — never
  the socket — is the authority on the order. Deleting goes through a
  confirmation modal, since it takes the answer options with it.
  """
  use LiveQuizWeb, :live_view

  alias LiveQuiz.Quizzes
  alias LiveQuizWeb.QuizLive.QuestionFormComponent

  @description_limit 500
  @letters ~w(A B C D)
  @text_preview_limit 120

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    quiz = Quizzes.get_quiz_with_questions!(socket.assigns.current_scope, id)

    {:ok,
     socket
     |> assign(:page_title, quiz.title)
     |> assign(:quiz, quiz)
     |> assign(:question, nil)
     |> assign(:question_to_delete, nil)
     |> assign(:invalid_field, nil)
     |> assign(:attempt, 0)
     |> assign_form(Quizzes.change_quiz(quiz))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, _params) do
    socket
    |> assign(:page_title, socket.assigns.quiz.title)
    |> assign(:question, nil)
  end

  defp apply_action(socket, :new_question, _params) do
    quiz = socket.assigns.quiz

    if limit_reached?(quiz) do
      socket
      |> put_flash(:error, limit_message())
      |> push_patch(to: ~p"/quizzes/#{quiz}/edit")
    else
      socket
      |> assign(:page_title, "Nova pergunta")
      |> assign(:question, Quizzes.new_question())
    end
  end

  defp apply_action(socket, :edit_question, %{"question_id" => question_id}) do
    question =
      Quizzes.get_question!(socket.assigns.current_scope, socket.assigns.quiz, question_id)

    socket
    |> assign(:page_title, "Editar pergunta")
    |> assign(:question, question)
  end

  @impl true
  def handle_event("validate_quiz", %{"quiz" => quiz_params}, socket) do
    changeset = Quizzes.change_quiz(socket.assigns.quiz, quiz_params)

    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save_quiz", %{"quiz" => quiz_params}, socket) do
    case Quizzes.update_quiz(socket.assigns.current_scope, socket.assigns.quiz, quiz_params) do
      {:ok, quiz} ->
        {:noreply,
         socket
         |> put_flash(:info, "Alterações salvas")
         |> assign(:quiz, %{quiz | questions: socket.assigns.quiz.questions})
         |> assign(:page_title, quiz.title)
         |> assign(:invalid_field, nil)
         |> assign_form(Quizzes.change_quiz(quiz))}

      {:error, :quiz_locked} ->
        {:noreply, refuse_locked(socket)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign_form(Map.put(changeset, :action, :update))
         |> assign(:invalid_field, first_invalid_field(changeset))
         |> update(:attempt, &(&1 + 1))}
    end
  end

  # The event only carries the id, so the question is loaded through the context
  # first: that is what proves the caller owns it — a foreign id raises
  # `Ecto.NoResultsError` and the request ends as a 404.
  def handle_event("move_question_up", %{"id" => id}, socket) do
    {:noreply, move(socket, id, :up)}
  end

  def handle_event("move_question_down", %{"id" => id}, socket) do
    {:noreply, move(socket, id, :down)}
  end

  def handle_event("delete_question", %{"id" => id}, socket) do
    question = Quizzes.get_question!(socket.assigns.current_scope, socket.assigns.quiz, id)

    {:noreply, assign(socket, :question_to_delete, question)}
  end

  def handle_event("cancel_delete_question", _params, socket) do
    {:noreply, assign(socket, :question_to_delete, nil)}
  end

  def handle_event("confirm_delete_question", _params, socket) do
    %{current_scope: scope, question_to_delete: question} = socket.assigns

    socket =
      case Quizzes.delete_question(scope, question) do
        {:ok, _deleted} -> put_flash(socket, :info, "Pergunta excluída")
        {:error, :quiz_locked} -> put_flash(socket, :error, locked_message())
      end

    {:noreply, socket |> assign(:question_to_delete, nil) |> reload_quiz()}
  end

  # `move_question/3` answers `{:ok, :unchanged}` at the edges: a movement that
  # had nowhere to go is a successful no-op, so both shapes end the same way.
  # A quiz with a live room refuses the move altogether (F2-07).
  defp move(socket, id, direction) do
    %{current_scope: scope, quiz: quiz} = socket.assigns

    question = Quizzes.get_question!(scope, quiz, id)

    case Quizzes.move_question(scope, question, direction) do
      {:ok, _moved} -> reload_quiz(socket)
      {:error, :quiz_locked} -> refuse_locked(socket)
    end
  end

  # The quiz is reloaded along with the message so the screen already carries
  # the room that caused the refusal, instead of the state it had before it.
  defp refuse_locked(socket) do
    socket
    |> put_flash(:error, locked_message())
    |> reload_quiz()
  end

  # The list is the context's answer, never a local edit of what was on screen.
  defp reload_quiz(socket) do
    quiz = Quizzes.get_quiz_with_questions!(socket.assigns.current_scope, socket.assigns.quiz.id)

    assign(socket, :quiz, quiz)
  end

  @impl true
  def handle_info({QuestionFormComponent, {:saved, message}}, socket) do
    socket = reload_quiz(socket)

    {:noreply,
     socket
     |> put_flash(:info, message)
     |> push_patch(to: ~p"/quizzes/#{socket.assigns.quiz}/edit")}
  end

  def handle_info({QuestionFormComponent, :quiz_locked}, socket) do
    socket = refuse_locked(socket)

    {:noreply, push_patch(socket, to: ~p"/quizzes/#{socket.assigns.quiz}/edit")}
  end

  def handle_info({QuestionFormComponent, :question_limit_reached}, socket) do
    socket = reload_quiz(socket)

    {:noreply,
     socket
     |> put_flash(:error, limit_message())
     |> push_patch(to: ~p"/quizzes/#{socket.assigns.quiz}/edit")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <nav aria-label="Trilha de navegação" class="mb-4 text-sm text-base-content/70">
        <ol class="flex flex-wrap items-center gap-2">
          <li>
            <.link navigate={~p"/quizzes"} class="link link-hover">Meus quizzes</.link>
          </li>
          <li aria-hidden="true">/</li>
          <li aria-current="page" class="font-medium text-base-content">{@quiz.title}</li>
        </ol>
      </nav>

      <.header>
        Editar quiz
        <:subtitle>Ajuste o título e a descrição do seu quiz.</:subtitle>
      </.header>

      <p
        :if={@quiz.locked?}
        id="quiz-locked-notice"
        role="status"
        class="mt-6 rounded-lg border border-warning bg-warning/10 p-4 text-warning-content"
      >
        {locked_hint()}. As alterações ficam bloqueadas até a sala ser encerrada.
      </p>

      <.focus_on_error target={@invalid_field} token={@attempt} />

      <.form
        for={@form}
        id="quiz-form"
        phx-change="validate_quiz"
        phx-submit="save_quiz"
        class="mt-6"
      >
        <.input field={@form[:title]} type="text" label="Título" required />

        <.input
          field={@form[:description]}
          type="textarea"
          label="Descrição (opcional)"
          rows="4"
          maxlength={@description_limit}
        />

        <p class="-mt-1 text-sm text-base-content/60" aria-live="polite">
          {remaining_characters(@form)} caracteres restantes
        </p>

        <div class="mt-4">
          <.button
            id="save-quiz-button"
            variant="primary"
            phx-disable-with="Salvando..."
            disabled={@quiz.locked?}
            aria-disabled={to_string(@quiz.locked?)}
            aria-describedby={locked_target(@quiz)}
          >
            Salvar
          </.button>
        </div>
      </.form>

      <section class="mt-10" aria-labelledby="questions-heading">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h2 id="questions-heading" class="text-lg font-semibold">Perguntas</h2>
            <p class="text-sm text-base-content/70">{questions_summary(@quiz)}</p>
          </div>

          <div class="flex flex-col items-start gap-1 sm:items-end">
            <.button
              :if={not blocked?(@quiz)}
              id="add-question-button"
              variant="primary"
              patch={~p"/quizzes/#{@quiz}/questions/new"}
              phx-click={JS.push_focus()}
            >
              Adicionar pergunta
            </.button>

            <button
              :if={blocked?(@quiz)}
              id="add-question-button"
              type="button"
              disabled
              aria-disabled="true"
              aria-describedby={blocked_target(@quiz)}
              class="btn btn-primary btn-disabled"
            >
              Adicionar pergunta
            </button>

            <p :if={limit_reached?(@quiz)} id="question-limit-hint" class="text-sm text-warning">
              {limit_hint()}
            </p>
          </div>
        </div>

        <div :if={@quiz.questions == []} id="questions-empty" class="mt-6 text-center">
          <p class="text-base-content/70">Este quiz ainda não tem perguntas</p>

          <div class="mt-4">
            <.button
              :if={not @quiz.locked?}
              id="first-question-button"
              variant="primary"
              patch={~p"/quizzes/#{@quiz}/questions/new"}
              phx-click={JS.push_focus()}
            >
              Adicionar pergunta
            </.button>
          </div>
        </div>

        <ol :if={@quiz.questions != []} id="questions" class="mt-6 space-y-3">
          <li
            :for={question <- @quiz.questions}
            id={"question-#{question.id}"}
            class="flex flex-wrap items-start justify-between gap-3 rounded-lg border border-base-300 p-4"
          >
            <div class="flex min-w-0 items-start gap-3">
              <span class="badge badge-neutral shrink-0">{question.position}</span>

              <div class="min-w-0">
                <p class="font-medium break-words">{preview(question.text)}</p>
                <p class="mt-1 text-sm text-success break-words">
                  Correta: {correct_answer(question)}
                </p>
              </div>
            </div>

            <div class="flex shrink-0 items-center gap-1">
              <button
                type="button"
                id={"move-question-up-#{question.id}"}
                disabled={question.position == 1 or @quiz.locked?}
                aria-describedby={locked_target(@quiz)}
                phx-click="move_question_up"
                phx-value-id={question.id}
                phx-disable-with="…"
                aria-label={"Mover pergunta #{question.position} para cima"}
                class="btn btn-ghost btn-sm"
              >
                <.icon name="hero-arrow-up" class="size-4" />
              </button>

              <button
                type="button"
                id={"move-question-down-#{question.id}"}
                disabled={question.position == last_position(@quiz) or @quiz.locked?}
                aria-describedby={locked_target(@quiz)}
                phx-click="move_question_down"
                phx-value-id={question.id}
                phx-disable-with="…"
                aria-label={"Mover pergunta #{question.position} para baixo"}
                class="btn btn-ghost btn-sm"
              >
                <.icon name="hero-arrow-down" class="size-4" />
              </button>

              <.link
                :if={not @quiz.locked?}
                patch={~p"/quizzes/#{@quiz}/questions/#{question}/edit"}
                phx-click={JS.push_focus()}
                class="btn btn-ghost btn-sm"
              >
                Editar
              </.link>

              <button
                :if={@quiz.locked?}
                type="button"
                id={"edit-question-#{question.id}"}
                disabled
                aria-disabled="true"
                aria-describedby={locked_target(@quiz)}
                class="btn btn-ghost btn-sm btn-disabled"
              >
                Editar
              </button>

              <button
                type="button"
                id={"delete-question-#{question.id}"}
                disabled={@quiz.locked?}
                aria-disabled={to_string(@quiz.locked?)}
                aria-describedby={locked_target(@quiz)}
                phx-click={JS.push_focus() |> JS.push("delete_question", value: %{id: question.id})}
                class={["btn btn-ghost btn-sm text-error", @quiz.locked? && "btn-disabled"]}
              >
                Excluir
              </button>
            </div>
          </li>
        </ol>
      </section>

      <.modal
        :if={@live_action in [:new_question, :edit_question] and @question}
        id="question-modal"
        title={modal_title(@live_action)}
        on_cancel={JS.patch(~p"/quizzes/#{@quiz}/edit") |> JS.pop_focus()}
      >
        <.live_component
          module={QuestionFormComponent}
          id={"question-form-#{@question.id || :new}"}
          quiz={@quiz}
          question={@question}
          current_scope={@current_scope}
          action={form_action(@live_action)}
          patch={~p"/quizzes/#{@quiz}/edit"}
        />
      </.modal>

      <.modal
        :if={@question_to_delete}
        id="delete-question"
        title="Excluir esta pergunta?"
        on_cancel={JS.push("cancel_delete_question") |> JS.pop_focus()}
      >
        <p class="font-medium break-words">{preview(@question_to_delete.text)}</p>

        <p class="mt-2 text-base-content/70">
          As 4 alternativas também serão removidas. Esta ação não pode ser desfeita.
        </p>

        <:actions>
          <button
            type="button"
            phx-click={JS.push("cancel_delete_question") |> JS.pop_focus()}
            class="btn btn-ghost"
          >
            Cancelar
          </button>

          <button
            type="button"
            phx-click="confirm_delete_question"
            phx-disable-with="Excluindo..."
            class="btn btn-error"
          >
            Excluir pergunta
          </button>
        </:actions>
      </.modal>
    </Layouts.app>
    """
  end

  # Only ever called from inside the list, which the template skips when the
  # quiz has no questions.
  defp last_position(%{questions: questions}), do: List.last(questions).position

  defp modal_title(:new_question), do: "Nova pergunta"
  defp modal_title(:edit_question), do: "Editar pergunta"

  defp form_action(:new_question), do: :new
  defp form_action(:edit_question), do: :edit

  defp limit_reached?(%{questions: questions}) when is_list(questions),
    do: length(questions) >= Quizzes.max_questions()

  # Two different reasons keep the "add question" affordance shut, and each one
  # points the screen reader at the sentence that explains it.
  defp blocked?(quiz), do: limit_reached?(quiz) or quiz.locked?

  defp blocked_target(quiz) do
    if limit_reached?(quiz), do: "question-limit-hint", else: locked_target(quiz)
  end

  defp locked_target(quiz), do: if(quiz.locked?, do: "quiz-locked-notice")

  defp limit_message, do: "Este quiz já atingiu o limite de #{Quizzes.max_questions()} perguntas"

  defp locked_message, do: "Este quiz possui uma sala ativa e não pode ser alterado"

  defp locked_hint, do: "Este quiz possui uma sala ativa"

  defp limit_hint, do: "Limite de #{Quizzes.max_questions()} perguntas atingido"

  defp preview(text) when is_binary(text) do
    if String.length(text) > @text_preview_limit do
      String.slice(text, 0, @text_preview_limit) <> "…"
    else
      text
    end
  end

  defp correct_answer(%{answer_options: options}) do
    case Enum.find(options, & &1.is_correct) do
      nil -> "—"
      option -> "#{letter(option.position)}. #{option.text}"
    end
  end

  defp letter(position), do: Enum.at(@letters, position - 1)

  defp assign_form(socket, changeset) do
    socket
    |> assign(:form, to_form(changeset, as: :quiz))
    |> assign(:description_limit, @description_limit)
  end

  defp remaining_characters(form) do
    used = form[:description].value |> to_string() |> String.length()

    max(@description_limit - used, 0)
  end

  defp first_invalid_field(changeset) do
    Enum.find_value([:title, :description], fn field ->
      if Keyword.has_key?(changeset.errors, field), do: "quiz_#{field}"
    end)
  end

  defp questions_summary(%{questions: []}), do: "Este quiz ainda não tem perguntas."
  defp questions_summary(%{questions: [_one]}), do: "1 pergunta."
  defp questions_summary(%{questions: questions}), do: "#{length(questions)} perguntas."
end
