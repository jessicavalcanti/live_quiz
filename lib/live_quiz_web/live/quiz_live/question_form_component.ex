defmodule LiveQuizWeb.QuizLive.QuestionFormComponent do
  @moduledoc """
  Modal form used to write a question and its four answer options.

  The component owns only the state of the form; the page around it owns the
  quiz. Every rule it enforces — the length of the texts, the single correct
  option, the repeated texts — comes back from the changeset the context
  builds, so nothing is validated twice.

  The correct option travels as a radio group over `position`, which makes two
  correct options impossible to express in the interface. Right before the
  params reach the context, the selection is expanded into `is_correct` for all
  four options: sending only the marked one would leave the other three with
  the value they had before.
  """
  use LiveQuizWeb, :live_component

  alias LiveQuiz.Quizzes

  @letters ~w(A B C D)

  @impl true
  def update(%{question: question} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:invalid_field, fn -> nil end)
     |> assign_new(:attempt, fn -> 0 end)
     |> assign_new(:correct_position, fn -> correct_position(question) end)
     |> assign_new(:form, fn -> to_form(Quizzes.change_question(question), as: :question) end)}
  end

  @impl true
  def handle_event("validate", %{"question" => params}, socket) do
    params = with_correct_option(params)

    changeset =
      socket.assigns.question
      |> Quizzes.change_question(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:correct_position, params["correct_position"])
     |> assign(:form, to_form(changeset, as: :question))}
  end

  def handle_event("save", %{"question" => params}, socket) do
    save_question(socket, socket.assigns.action, with_correct_option(params))
  end

  defp save_question(socket, :new, params) do
    case Quizzes.create_question(socket.assigns.current_scope, socket.assigns.quiz, params) do
      {:ok, _question} ->
        notify_parent({:saved, "Pergunta adicionada"})
        {:noreply, socket}

      {:error, :question_limit_reached} ->
        notify_parent(:question_limit_reached)
        {:noreply, socket}

      {:error, :quiz_locked} ->
        notify_parent(:quiz_locked)
        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, refuse(socket, changeset, params, :insert)}
    end
  end

  defp save_question(socket, :edit, params) do
    case Quizzes.update_question(socket.assigns.current_scope, socket.assigns.question, params) do
      {:ok, _question} ->
        notify_parent({:saved, "Pergunta atualizada"})
        {:noreply, socket}

      {:error, :quiz_locked} ->
        notify_parent(:quiz_locked)
        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, refuse(socket, changeset, params, :update)}
    end
  end

  # Keeping the params the user typed is the point: the modal stays open with
  # the same content, only now carrying the errors.
  defp refuse(socket, changeset, params, action) do
    changeset = Map.put(changeset, :action, action)

    socket
    |> assign(:correct_position, params["correct_position"])
    |> assign(:form, to_form(changeset, as: :question))
    |> assign(:invalid_field, first_invalid_field(changeset))
    |> assign(:attempt, socket.assigns.attempt + 1)
  end

  defp notify_parent(message), do: send(self(), {__MODULE__, message})

  # The radio only says *which* option is correct. The context needs the answer
  # for each of the four, so the selection is expanded here before it leaves.
  defp with_correct_option(params) do
    correct = params["correct_position"]

    options =
      params
      |> Map.get("answer_options", %{})
      |> Map.new(fn {index, option} ->
        {index, Map.put(option, "is_correct", to_string(option["position"]) == correct)}
      end)

    Map.put(params, "answer_options", options)
  end

  defp correct_position(%{answer_options: options}) do
    Enum.find_value(options, fn option ->
      if option.is_correct, do: to_string(option.position)
    end)
  end

  defp first_invalid_field(changeset) do
    if Keyword.has_key?(changeset.errors, :text) do
      "question_text"
    else
      first_invalid_option(changeset)
    end
  end

  defp first_invalid_option(changeset) do
    changeset
    |> Ecto.Changeset.get_change(:answer_options, [])
    |> Enum.with_index()
    |> Enum.find_value(fn {option, index} ->
      if option.errors != [], do: "question_answer_options_#{index}_text"
    end)
  end

  # Errors about the *set* of options — no correct one, repeated texts — live on
  # the parent changeset. Rendering them only under the fields would hide them,
  # so they get a block of their own at the top of the modal.
  defp set_errors(%{source: %Ecto.Changeset{action: nil}}), do: []

  defp set_errors(%{source: %Ecto.Changeset{} = changeset}) do
    changeset.errors
    |> Keyword.get_values(:answer_options)
    |> Enum.map(&translate_error/1)
  end

  defp letter(position) do
    case Integer.parse(to_string(position)) do
      {number, ""} -> Enum.at(@letters, number - 1) || to_string(position)
      _other -> to_string(position)
    end
  end

  defp option_position(option_form) do
    to_string(option_form[:position].value)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.focus_on_error target={@invalid_field} token={@attempt} />

      <.form
        for={@form}
        id="question-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <div
          :if={set_errors(@form) != []}
          id="question-set-errors"
          role="alert"
          class="mb-4 rounded-lg border border-destructive/40 bg-destructive/10 p-3 text-sm text-destructive"
        >
          <p :for={message <- set_errors(@form)}>{message}</p>
        </div>

        <.input
          field={@form[:text]}
          type="textarea"
          label="Texto da pergunta"
          rows="3"
          required
        />

        <fieldset class="mt-2">
          <legend class="mb-2 text-sm leading-none font-medium">
            Alternativas (marque a correta)
          </legend>

          <div class="space-y-2">
            <%!--
              The radio and the text field belong to different form keys — the
              radio carries `correct_position` while the text belongs to the
              option itself — so each row is one card holding both, which is also
              what makes the chosen alternative visible as a row rather than as a
              dot in a column of its own.
            --%>
            <.inputs_for :let={option} field={@form[:answer_options]}>
              <div class={[
                "flex items-start gap-3 rounded-lg border p-3 transition-colors",
                @correct_position == option_position(option) &&
                  "border-success/50 bg-success/5",
                @correct_position != option_position(option) && "border-border"
              ]}>
                <.input field={option[:position]} type="hidden" />

                <label
                  for={"question-correct-#{option_position(option)}"}
                  class="mt-8 flex shrink-0 cursor-pointer items-center gap-2"
                >
                  <input
                    type="radio"
                    id={"question-correct-#{option_position(option)}"}
                    name="question[correct_position]"
                    value={option_position(option)}
                    checked={@correct_position == option_position(option)}
                    class="size-4 shrink-0 accent-primary focus-visible:ring-[3px] focus-visible:ring-ring/50 focus-visible:outline-hidden"
                  />
                  <span class="text-sm font-semibold">{letter(option_position(option))}</span>
                  <span class="sr-only">é a alternativa correta</span>
                </label>

                <div class="grow">
                  <.input
                    field={option[:text]}
                    type="text"
                    label={"Alternativa #{letter(option_position(option))}"}
                    required
                  />
                </div>
              </div>
            </.inputs_for>
          </div>
        </fieldset>

        <div class="mt-6 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <.button patch={@patch} phx-click={JS.pop_focus()} variant="ghost">
            Cancelar
          </.button>

          <.button phx-disable-with="Salvando...">
            Salvar pergunta
          </.button>
        </div>
      </.form>
    </div>
    """
  end
end
