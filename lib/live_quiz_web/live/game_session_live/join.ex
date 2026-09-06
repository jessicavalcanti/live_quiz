defmodule LiveQuizWeb.GameSessionLive.Join do
  @moduledoc """
  The door into a room, and the only screen of the platform someone without an
  account ever uses.

  Three ways of arriving end here and become the same decision. Someone types a
  code heard out loud, someone opens a link, someone points a camera at a QR
  code on the wall; the link and the QR code only fill the code in, so what is
  always left is *which nickname I am going to use*. That is why there is one
  screen and not three.

  Nothing about a room is decided here. The nickname rules and the code format
  come from `LiveQuiz.Games.change_join/1`, the entry itself from
  `LiveQuiz.Games.join_game_session/4`, and each of its five refusals is worded
  differently because each one asks for a different next move — collapsing them
  into "não foi possível entrar" would leave someone retyping a nickname when
  the room is simply full.

  Nothing throttles the attempts here — the phase took that risk knowingly — so
  the tries on codes that do not exist are at least written to the log, which is
  what will say whether anybody is walking the code space before phase 3 decides
  what to do about it.

  Uniqueness of the nickname is the one rule not checked while typing: two
  guests racing for "Ana" make any answer given before the submit a promise the
  server cannot keep, so it is settled once, by the unique index.

  Before entering, all that is shown is the quiz title and whether the room
  still takes people (AD-35). The list of participants, and even how many there
  are, belongs to whoever is already inside.

  A LiveView cannot write cookies, so the credential is not stored here. Once
  the context has accepted the entry the form posts itself to
  `LiveQuizWeb.GameSessionController` through `phx-trigger-action`, carrying the
  clear token in the body of that single request — never in the address of the
  lobby, which would leave the credential in the browser history.
  """
  use LiveQuizWeb, :live_view

  require Logger

  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.JoinCode
  alias LiveQuiz.Games.Participant

  @impl true
  def mount(params, _session, socket) do
    code = params |> Map.get("code", "") |> JoinCode.normalize()

    socket =
      socket
      |> assign(:page_title, "Entrar em uma sala")
      |> assign(:trigger_submit, false)
      |> assign(:token, nil)
      |> assign(:error, nil)
      |> assign(:join_code_length, GameSession.join_code_length())
      |> assign(:nickname_max_length, Participant.nickname_max_length())
      |> assign_form(%{"code" => code, "nickname" => suggested_nickname(socket)})
      |> load_preview(code)

    {:ok, redirect_if_already_in(socket, code)}
  end

  @impl true
  def handle_event("validate", %{"join" => params}, socket) do
    code = params |> Map.get("code", "") |> JoinCode.normalize()

    socket =
      socket
      |> assign(:error, nil)
      |> assign_form(params, action: :validate)

    {:noreply, if(code == socket.assigns.code, do: socket, else: load_preview(socket, code))}
  end

  def handle_event("join", %{"join" => params}, socket) do
    changeset = Games.change_join(params)

    if changeset.valid? do
      {:noreply, attempt_join(socket, params)}
    else
      {:noreply, assign_form(socket, params, action: :validate)}
    end
  end

  # The token exists only in this answer, so it goes straight into the hidden
  # field the browser is about to post and is never assigned anywhere a later
  # render could put it back on screen.
  defp attempt_join(socket, params) do
    %{current_scope: scope, participant_tokens: tokens} = socket.assigns
    code = params |> Map.get("code", "") |> JoinCode.normalize()

    case Games.join_game_session(scope, code, params, known_tokens: Map.values(tokens)) do
      {:ok, _participant, token} ->
        socket
        |> assign(:token, token)
        |> assign(:form_code, code)
        |> assign(:trigger_submit, true)

      {:error, :nickname_taken} ->
        assign_form(socket, params,
          action: :validate,
          nickname_error: {"este apelido já está em uso nesta sala", []}
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        refuse_with_changeset(socket, params, code, changeset)

      {:error, reason} ->
        log_refusal(reason, code)

        socket
        |> assign(:error, reason)
        |> load_preview(code)
    end
  end

  # There is no rate limiting on this screen in this phase, a risk taken
  # knowingly. Counting the attempts on codes that do not exist is what will
  # tell phase 3 whether anybody is actually walking the code space.
  defp log_refusal(:session_not_found, code) do
    Logger.info("join attempt on unknown room code #{inspect(code)}")
  end

  defp log_refusal(_reason, _code), do: :ok

  # A changeset only comes back for something the typed form could not have
  # caught. When it is about the nickname it belongs on that field; anything
  # else has no field to sit on and becomes the generic refusal.
  defp refuse_with_changeset(socket, params, code, changeset) do
    case Keyword.get_values(changeset.errors, :nickname) do
      [error | _rest] ->
        assign_form(socket, params, action: :validate, nickname_error: error)

      [] ->
        socket
        |> assign(:error, :invalid)
        |> load_preview(code)
    end
  end

  # Whoever already holds a credential for this room is taken straight in: the
  # nickname was chosen once and coming back is not a new sign-up.
  defp redirect_if_already_in(socket, code) do
    token = Map.get(socket.assigns.participant_tokens, code)

    case Games.get_participant_of_session(token, code) do
      {:ok, _participant} -> redirect(socket, to: lobby_path(code))
      {:error, :not_found} -> socket
    end
  end

  defp load_preview(socket, code) do
    preview =
      case Games.preview_by_code(code) do
        {:ok, preview} -> preview
        {:error, :not_found} -> nil
      end

    socket
    |> assign(:code, code)
    |> assign(:session_preview, preview)
  end

  defp assign_form(socket, params, opts \\ []) do
    changeset =
      params
      |> Map.take(["code", "nickname"])
      |> Games.change_join()
      |> add_nickname_error(Keyword.get(opts, :nickname_error))

    socket
    |> assign(:form, to_form(changeset, as: :join, action: Keyword.get(opts, :action)))
    |> assign(:form_code, params |> Map.get("code", "") |> JoinCode.normalize())
  end

  defp add_nickname_error(changeset, nil), do: changeset

  defp add_nickname_error(changeset, {message, opts}) do
    Ecto.Changeset.add_error(changeset, :nickname, message, opts)
  end

  defp suggested_nickname(socket) do
    Games.suggested_nickname(socket.assigns[:current_scope]) || ""
  end

  defp lobby_path(code), do: ~p"/game-sessions/#{code}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-md space-y-6">
        <.header>
          Entrar em uma sala
          <:subtitle>
            Informe o código da sala e escolha como você quer aparecer para todo mundo.
          </:subtitle>
        </.header>

        <div :if={@session_preview} id="session-preview" class="rounded-xl border border-base-300 p-4">
          <p class="text-xs font-semibold tracking-widest text-base-content/60 uppercase">Quiz</p>

          <p id="preview-quiz-title" class="mt-1 text-lg font-bold break-words">
            {@session_preview.quiz_title}
          </p>

          <p
            id="preview-availability"
            class={[
              "mt-2 text-sm",
              if(@session_preview.available, do: "text-success", else: "text-warning")
            ]}
          >
            {availability_label(@session_preview)}
          </p>
        </div>

        <p
          :if={@error}
          id="join-error"
          role="alert"
          class="rounded-lg border border-error bg-error/10 p-4 text-sm text-error"
        >
          {error_message(@error)}
        </p>

        <.form
          for={@form}
          id="join-form"
          action={~p"/game-sessions/join"}
          method="post"
          phx-change="validate"
          phx-submit="join"
          phx-trigger-action={@trigger_submit}
          class="space-y-4"
        >
          <input type="hidden" name="code" value={@form_code} />
          <input :if={@token} type="hidden" name="token" value={@token} />

          <.input
            field={@form[:code]}
            type="text"
            label="Código da sala"
            placeholder="K7P4Q2"
            autocomplete="off"
            autocapitalize="characters"
            spellcheck="false"
            maxlength={@join_code_length}
            required
          />

          <.input
            field={@form[:nickname]}
            type="text"
            label="Seu apelido"
            placeholder="Como você quer aparecer"
            autocomplete="nickname"
            maxlength={@nickname_max_length}
            aria-describedby="nickname-hint"
            required
          />

          <p id="nickname-hint" class="text-sm text-base-content/70">
            Depois de entrar, o apelido não pode ser trocado.
          </p>

          <.button id="join-submit" variant="primary" phx-disable-with="Entrando..." class="w-full">
            Entrar na sala
          </.button>
        </.form>

        <p class="text-center text-sm text-base-content/70">
          Não é preciso ter conta para participar.
        </p>
      </div>
    </Layouts.app>
    """
  end

  defp availability_label(%{available: true}), do: "Sala aberta para entrada."
  defp availability_label(%{available: false}), do: "Esta sala não está aceitando entradas."

  defp error_message(:session_not_found), do: "Sala não encontrada."
  defp error_message(:session_not_joinable), do: "Esta partida já começou."
  defp error_message(:session_full), do: "Sala lotada."

  defp error_message(:already_in_another_session),
    do: "Você já está em outra sala. Saia dela para entrar aqui."

  defp error_message(_reason), do: "Não foi possível entrar na sala. Tente novamente."
end
