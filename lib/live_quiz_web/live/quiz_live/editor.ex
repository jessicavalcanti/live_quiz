defmodule LiveQuizWeb.QuizLive.Editor do
  @moduledoc """
  Editor of a single quiz: its title and description now, its questions from
  F1-11 on.

  The quiz is loaded through the context with the caller scope, so a quiz that
  belongs to somebody else raises `Ecto.NoResultsError` and the request ends as
  a 404 — the same answer a quiz that never existed would get.
  """
  use LiveQuizWeb, :live_view

  alias LiveQuiz.Quizzes

  @description_limit 500

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    quiz = Quizzes.get_quiz_with_questions!(socket.assigns.current_scope, id)

    {:ok,
     socket
     |> assign(:page_title, quiz.title)
     |> assign(:quiz, quiz)
     |> assign(:invalid_field, nil)
     |> assign(:attempt, 0)
     |> assign_form(Quizzes.change_quiz(quiz))}
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
         |> assign(:quiz, quiz)
         |> assign(:page_title, quiz.title)
         |> assign(:invalid_field, nil)
         |> assign_form(Quizzes.change_quiz(quiz))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign_form(Map.put(changeset, :action, :update))
         |> assign(:invalid_field, first_invalid_field(changeset))
         |> update(:attempt, &(&1 + 1))}
    end
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
          <.button variant="primary" phx-disable-with="Salvando...">Salvar</.button>
        </div>
      </.form>

      <section class="mt-10" aria-labelledby="questions-heading">
        <h2 id="questions-heading" class="text-lg font-semibold">Perguntas</h2>

        <p class="mt-2 text-base-content/70">
          {questions_summary(@quiz)}
        </p>
      </section>
    </Layouts.app>
    """
  end

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

  defp questions_summary(%{questions: []}),
    do: "Este quiz ainda não tem perguntas. A edição de perguntas chega na próxima entrega."

  defp questions_summary(%{questions: questions}),
    do: "Este quiz tem #{length(questions)} pergunta(s). A edição chega na próxima entrega."
end
