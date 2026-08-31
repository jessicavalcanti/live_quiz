defmodule LiveQuizWeb.GameSessionLive.Host do
  @moduledoc """
  The lobby the host projects on the wall, and the control panel of the room.

  The address carries the join code rather than the room id: the host reads it
  out loud and sees it in the browser bar, and nothing sequential is exposed.
  The room is still read through the caller scope, so the lobby of somebody
  else's room is indistinguishable from a room that never existed — both end as
  a 404. A room that is already over keeps answering here, because a host who
  comes back has to learn whether it was cancelled or whether it expired.

  Every assign is filled from `LiveQuiz.Games` and refreshed by the events of
  the room topic (AD-31): there is no polling and no timer. The connected mount
  registers the host in the presence, which is what sustains the absence
  detection of F2-06, and claims the access of the room — another tab claiming
  it later leaves this screen with `access_lost?` and no commands.

  The screen decides nothing: the "Iniciar partida" button is disabled while
  nobody is connected, but the guarantee is in `start_game_session/3`, which
  re-reads the lobby at the instant of the click and refuses a room with an
  empty floor even if the button was forced back to life in the DOM.
  """
  use LiveQuizWeb, :live_view

  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.Presence
  alias LiveQuizWeb.Formatters
  alias Phoenix.Socket.Broadcast

  @impl true
  def mount(%{"code" => code}, _session, socket) do
    session = Games.get_hosted_session_by_code!(socket.assigns.current_scope, code)

    socket =
      socket
      |> assign(:page_title, session.quiz_title)
      |> assign(:session, session)
      |> assign(:connection_id, nil)
      |> assign(:access_lost?, false)
      |> assign(:show_cancel_modal?, false)
      |> assign(:expires_at, session.expires_at)
      |> assign(:max_participants, Games.max_participants())

    {:ok, socket |> take_over() |> load_lobby()}
  end

  # Subscribing or tracking in the disconnected mount would leave the static
  # render holding a subscription no process is going to consume, and would
  # announce a host who is not there yet. A room that is already over is only
  # read: taking its access over would announce a transfer nobody can use.
  defp take_over(socket) do
    %{current_scope: scope, session: session} = socket.assigns

    if connected?(socket) and GameSession.active?(session) do
      :ok = Games.subscribe(session.id)
      {:ok, session, connection_id} = Games.claim_host_connection(scope, session)
      {:ok, _ref} = Presence.track_host(self(), session, connection_id)

      socket
      |> assign(:session, session)
      |> assign(:connection_id, connection_id)
      |> assign(:expires_at, session.expires_at)
    else
      socket
    end
  end

  # The lobby is always the context's answer, never a local edit of what was on
  # screen: "inscritos" counts every seat ever taken, while "conectados" is
  # derived from the very list being shown, so the two numbers can never
  # disagree with each other.
  defp load_lobby(socket) do
    %{current_scope: scope, session: session} = socket.assigns
    {:ok, participants} = Games.list_participants_with_presence(session, scope)

    socket
    |> stream(:participants, participants, reset: true)
    |> assign(:participants_empty?, participants == [])
    |> assign(:reserved_slots, Games.reserved_slots(session))
    |> assign(:connected_count, Enum.count(participants, & &1.connected))
  end

  @impl true
  def handle_event("start", _params, socket) do
    if socket.assigns.access_lost? do
      {:noreply, socket}
    else
      # Re-read before deciding: the assign may be a few milliseconds behind
      # the floor, and it is the count at the instant of the click that the
      # context judges.
      socket = load_lobby(socket)
      %{current_scope: scope, session: session, connected_count: connected} = socket.assigns

      case Games.start_game_session(scope, session, connected) do
        {:ok, session} -> {:noreply, assign(socket, :session, session)}
        {:error, reason} -> {:noreply, put_flash(socket, :error, refusal(reason))}
      end
    end
  end

  def handle_event("open_cancel", _params, socket) do
    {:noreply, assign(socket, :show_cancel_modal?, true)}
  end

  def handle_event("close_cancel", _params, socket) do
    {:noreply, assign(socket, :show_cancel_modal?, false)}
  end

  def handle_event("confirm_cancel", _params, socket) do
    socket = assign(socket, :show_cancel_modal?, false)

    if socket.assigns.access_lost? do
      {:noreply, socket}
    else
      %{current_scope: scope, session: session} = socket.assigns

      case Games.cancel_game_session(scope, session) do
        {:ok, session} -> {:noreply, close(socket, session)}
        {:error, reason} -> {:noreply, put_flash(socket, :error, refusal(reason))}
      end
    end
  end

  # The clipboard write itself is the hook's job; the server only confirms it,
  # so the host projecting the screen sees that the click did something.
  def handle_event("copy_code", _params, socket) do
    {:noreply, put_flash(socket, :info, "Código copiado")}
  end

  # `Phoenix.Presence` publishes its raw diff on the same topic. The nudge this
  # screen reacts to is `{:presence_changed, id}`, announced by
  # `LiveQuiz.Games.Presence` right after it, so the diff itself is dropped
  # instead of costing a second read of the lobby.
  @impl true
  def handle_info(%Broadcast{event: "presence_diff"}, socket) do
    {:noreply, socket}
  end

  def handle_info({:participant_joined, _participant}, socket) do
    {:noreply, load_lobby(socket)}
  end

  def handle_info({:participant_left, _participant}, socket) do
    {:noreply, load_lobby(socket)}
  end

  def handle_info({:participant_rejoined, _participant}, socket) do
    {:noreply, load_lobby(socket)}
  end

  def handle_info({:presence_changed, _session_id}, socket) do
    {:noreply, load_lobby(socket)}
  end

  def handle_info({:access_transferred, _participant_id, _connection_id}, socket) do
    {:noreply, load_lobby(socket)}
  end

  # The claim of the connected mount reaches this screen too, carrying its own
  # id: losing the room is what another id means.
  def handle_info({:host_access_transferred, connection_id}, socket) do
    if connection_id == socket.assigns.connection_id do
      {:noreply, socket}
    else
      {:noreply, assign(socket, :access_lost?, true)}
    end
  end

  def handle_info({:game_started, session}, socket) do
    {:noreply, socket |> assign(:session, session) |> load_lobby()}
  end

  def handle_info({:game_cancelled, session}, socket) do
    {:noreply, close(socket, session)}
  end

  def handle_info({:game_expired, session}, socket) do
    {:noreply, close(socket, session)}
  end

  def handle_info({:host_disconnected, expires_at}, socket) do
    {:noreply, assign(socket, :expires_at, expires_at)}
  end

  def handle_info({:host_connected, _expires_at}, socket) do
    {:noreply, assign(socket, :expires_at, nil)}
  end

  defp close(socket, session) do
    socket
    |> assign(:session, session)
    |> assign(:expires_at, nil)
    |> assign(:show_cancel_modal?, false)
    |> load_lobby()
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
          <li aria-current="page" class="font-medium text-base-content">{@session.quiz_title}</li>
        </ol>
      </nav>

      <.header>
        {@session.quiz_title}
        <:subtitle>{subtitle(@session)}</:subtitle>
      </.header>

      <p
        :if={@access_lost?}
        id="access-lost-notice"
        role="alert"
        class="mt-6 rounded-lg border border-warning bg-warning/10 p-4 text-warning-content"
      >
        O controle desta sala foi assumido em outro dispositivo. Esta tela deixou de
        aceitar comandos.
      </p>

      <p
        :if={@expires_at && active?(@session)}
        id="expiration-notice"
        role="alert"
        class="mt-6 rounded-lg border border-warning bg-warning/10 p-4 text-warning-content"
      >
        Sua sala ficou sem host e será encerrada por ausência em {Formatters.format_datetime(
          @expires_at
        )} se o controle não for retomado.
      </p>

      <section
        :if={waiting?(@session)}
        id="join-code-panel"
        class="mt-8 rounded-2xl border border-base-300 p-8 text-center"
      >
        <p class="text-sm font-semibold tracking-[0.35em] text-base-content/70 uppercase">
          Código da sala
        </p>

        <p
          id="join-code"
          class="mt-4 font-mono text-6xl font-black tracking-[0.25em] break-all sm:text-8xl"
        >
          {@session.join_code}
        </p>

        <button
          type="button"
          id="copy-code"
          phx-click="copy_code"
          phx-hook=".CopyCode"
          data-code={@session.join_code}
          class="btn btn-soft btn-sm mt-6"
        >
          <.icon name="hero-clipboard-document" class="size-4" /> Copiar código
        </button>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyCode">
          export default {
            mounted() {
              this.el.addEventListener("click", () => {
                const code = this.el.dataset.code
                if (navigator.clipboard) { navigator.clipboard.writeText(code) }
              })
            }
          }
        </script>
      </section>

      <section
        :if={started?(@session)}
        id="game-started"
        class="mt-8 rounded-2xl border border-success p-8 text-center"
      >
        <h2 class="text-4xl font-black">Partida iniciada</h2>
        <p class="mt-3 text-base-content/70">
          As perguntas chegam na próxima fase. Novas inscrições estão encerradas.
        </p>
      </section>

      <section :if={active?(@session)} class="mt-8 space-y-6">
        <div class="flex flex-wrap items-center justify-center gap-x-10 gap-y-2 text-lg">
          <p id="reserved-count">
            Inscritos: <strong>{@reserved_slots}</strong> de {@max_participants}
          </p>
          <p id="connected-count">
            Conectados agora: <strong>{@connected_count}</strong>
          </p>
        </div>

        <p
          :if={@reserved_slots >= @max_participants}
          id="room-full-notice"
          class="text-center text-sm text-warning"
        >
          Sala lotada: as {@max_participants} vagas já foram ocupadas.
        </p>

        <p :if={@participants_empty?} id="participants-empty" class="text-center text-base-content/70">
          Ninguém entrou ainda. Compartilhe o código da sala.
        </p>

        <ul
          id="participants"
          phx-update="stream"
          class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3"
        >
          <li
            :for={{dom_id, participant} <- @streams.participants}
            id={dom_id}
            class="flex items-center gap-3 rounded-lg border border-base-300 p-3"
          >
            <span
              aria-hidden="true"
              class={[
                "size-3 shrink-0 rounded-full",
                if(participant.connected, do: "bg-success", else: "bg-base-300")
              ]}
            ></span>

            <span class="min-w-0 font-medium break-words">{participant.nickname}</span>

            <span :if={not participant.connected} class="ml-auto text-sm text-warning">
              desconectado
            </span>
          </li>
        </ul>

        <div class="flex flex-col items-center gap-2">
          <div class="flex flex-wrap items-center justify-center gap-4">
            <button
              :if={waiting?(@session)}
              type="button"
              id="start-game"
              phx-click="start"
              disabled={not startable?(assigns)}
              aria-disabled={to_string(not startable?(assigns))}
              aria-describedby={hint_target(assigns)}
              class={["btn btn-primary btn-lg", not startable?(assigns) && "btn-disabled"]}
            >
              Iniciar partida
            </button>

            <button
              type="button"
              id="cancel-room"
              phx-click="open_cancel"
              disabled={@access_lost?}
              aria-disabled={to_string(@access_lost?)}
              class={["btn btn-ghost text-error", @access_lost? && "btn-disabled"]}
            >
              Cancelar sala
            </button>
          </div>

          <p :if={hint(assigns)} id="start-hint" class="text-sm text-warning">{hint(assigns)}</p>
        </div>
      </section>

      <section
        :if={not active?(@session)}
        id="room-closed"
        class="mt-10 space-y-4 text-center"
      >
        <h2 class="text-3xl font-bold">{closed_title(@session)}</h2>
        <p class="text-base-content/70">{closed_message(@session)}</p>

        <div>
          <.button id="back-to-quizzes" variant="primary" navigate={~p"/quizzes"}>
            Voltar para Meus quizzes
          </.button>
        </div>
      </section>

      <.modal
        :if={@show_cancel_modal?}
        id="cancel-room-modal"
        title="Cancelar esta sala?"
        on_cancel={JS.push("close_cancel")}
      >
        <p class="text-base-content/70">
          Todos os participantes serão avisados do encerramento. Uma sala cancelada não
          pode ser reaberta: para jogar de novo, abra outra sala, com um novo código.
        </p>

        <:actions>
          <button type="button" phx-click="close_cancel" class="btn btn-ghost">
            Manter a sala
          </button>

          <button
            type="button"
            id="confirm-cancel"
            phx-click="confirm_cancel"
            phx-disable-with="Cancelando..."
            class="btn btn-error"
          >
            Sim, cancelar
          </button>
        </:actions>
      </.modal>
    </Layouts.app>
    """
  end

  defp active?(%GameSession{} = session), do: GameSession.active?(session)

  defp waiting?(%GameSession{status: status}), do: status == :waiting

  defp started?(%GameSession{status: status}), do: status == :in_progress

  defp startable?(%{connected_count: connected, access_lost?: lost?}) do
    connected > 0 and not lost?
  end

  defp hint(%{access_lost?: true}), do: nil

  defp hint(%{session: %GameSession{status: :waiting}, connected_count: 0}),
    do: "Ninguém está conectado ainda: a partida começa com pelo menos uma pessoa na sala."

  defp hint(_assigns), do: nil

  defp hint_target(assigns), do: if(hint(assigns), do: "start-hint")

  defp subtitle(%GameSession{status: :waiting}),
    do: "Compartilhe o código, acompanhe quem chega e comece quando quiser."

  defp subtitle(%GameSession{status: :in_progress}), do: "A partida está em andamento."
  defp subtitle(_session), do: "Esta sala foi encerrada."

  defp closed_title(%GameSession{status: :cancelled}), do: "Sala cancelada"
  defp closed_title(%GameSession{status: :expired}), do: "Sala encerrada por ausência"
  defp closed_title(_session), do: "Partida encerrada"

  defp closed_message(%GameSession{status: :cancelled}),
    do: "Você cancelou esta sala e os participantes foram avisados. Abra outra quando quiser."

  defp closed_message(%GameSession{status: :expired}),
    do:
      "A sala ficou sem host por mais de #{div(Games.host_absence_timeout(), 60)} minutos e foi " <>
        "encerrada. Abra outra sala para jogar de novo."

  defp closed_message(_session),
    do: "Esta partida chegou ao fim. Abra outra sala para jogar de novo."

  defp refusal(:no_connected_participants),
    do: "A partida só começa com pelo menos uma pessoa conectada"

  defp refusal(:invalid_transition), do: "Esta sala não está mais no estado necessário"
  defp refusal(_reason), do: "Não foi possível concluir a ação. Tente novamente."
end
