defmodule LiveQuizWeb.GameSessionLive.Host do
  @moduledoc """
  The lobby the host projects on the wall, the control panel of the room and,
  once the match starts, the screen the presentation is run from.

  It is a single address on purpose: the host who reconnects lands where the
  room actually is instead of being redirected at every transition, and the
  lobby of phase 2 gives way to the match the moment `{:game_started, session}`
  arrives. What the screen shows about the match is `Games.game_state/2` —
  plus `question_results/3` at the reveal and `game_summary/2` at the ending —
  and nothing else — where the match is, what the current question says, when it
  ends, how many people have answered — so the screen never decides whether the
  time is up, whether everybody answered or whether this was the last question.

  The countdown is decorative (AD-39): the server sends the absolute deadline
  and a hook draws the seconds against the reader's own clock, so latency ages
  nothing. Reaching zero on screen closes no question — the timer of F3-05 does,
  and the reveal arrives as `{:question_closed, session}` like any other event.

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
  alias LiveQuizWeb.GameOver
  alias LiveQuizWeb.QuestionResults
  alias LiveQuizWeb.Ranking
  alias LiveQuizWeb.ShareSession
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
      |> assign(:show_finish_modal?, false)
      |> assign(:expires_at, session.expires_at)
      |> assign(:max_participants, Games.max_participants())
      # How many questions the match has is settled the moment the room exists:
      # a live room locks its quiz against edits (AD-32) and the snapshot copies
      # it whole (AD-36), so the number read here survives the start.
      |> assign(:question_count, Games.question_count(session))
      |> assign(:join_url, ShareSession.join_url(session.join_code))
      |> assign(:ranking, nil)

    {:ok, socket |> take_over() |> load_lobby() |> load_match() |> load_summary()}
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
    # The denominator of "Respostas: 17 / 25" is the same list: whoever left is
    # out, whoever merely dropped off is in, because they are still someone who
    # has not answered.
    |> assign(:participants_count, length(participants))
  end

  # The whole match in one read (F3-03), never an edit of what was on screen: a
  # reload, a reconnection and an event all rebuild the same assign from the
  # database, which is why the countdown a host who comes back sees is the one
  # that is actually left.
  defp load_match(socket) do
    %{current_scope: scope, session: session} = socket.assigns

    if started?(session) do
      {:ok, state} = Games.game_state(session, scope)

      socket
      |> assign(:game_state, state)
      |> assign(:answers_count, state.answers_count)
      |> load_results(state)
      |> load_ranking(state)
    else
      socket
      |> assign(:game_state, nil)
      |> assign(:answers_count, 0)
      |> assign(:results, nil)
      |> assign(:ranking, nil)
    end
  end

  # The tally is only ever asked for once the question is done with: while it is
  # open the context refuses it (AD-46), and the screen has no answer key to
  # draw until the reveal. A refusal is read as "nothing to reveal yet" rather
  # than as an error, because the very question this screen believed was closed
  # may have been reopened by nobody but a race with the timer.
  defp load_results(socket, %{question_state: :closed, question_number: position}) do
    %{current_scope: scope, session: session} = socket.assigns

    case Games.question_results(session, position, scope) do
      {:ok, results} -> assign(socket, :results, results)
      {:error, _nothing_to_reveal} -> assign(socket, :results, nil)
    end
  end

  defp load_results(socket, _open_or_pending), do: assign(socket, :results, nil)

  defp load_ranking(socket, %{question_state: :closed}) do
    %{current_scope: scope, session: session} = socket.assigns

    case Games.current_ranking(session, scope) do
      {:ok, ranking} -> assign(socket, :ranking, ranking)
      {:error, :unauthorized} -> assign(socket, :ranking, nil)
    end
  end

  defp load_ranking(socket, _state), do: assign(socket, :ranking, nil)

  defp load_final_ranking(socket, %GameSession{status: :finished} = session) do
    case Games.current_ranking(session, socket.assigns.current_scope) do
      {:ok, ranking} -> assign(socket, :ranking, ranking)
      {:error, :unauthorized} -> assign(socket, :ranking, nil)
    end
  end

  defp load_final_ranking(socket, _session), do: assign(socket, :ranking, nil)

  # What the match added up to, read only when the room is over: asking for it
  # while it is running would cost a query per event for a number no screen of
  # this phase shows before the ending.
  defp load_summary(socket) do
    %{current_scope: scope, session: session} = socket.assigns

    if GameSession.active?(session) do
      assign(socket, :summary, nil)
    else
      {:ok, summary} = Games.game_summary(session, scope)

      assign(socket, :summary, summary)
    end
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
        {:ok, session} -> {:noreply, socket |> assign(:session, session) |> load_match()}
        {:error, reason} -> {:noreply, put_flash(socket, :error, refusal(reason))}
      end
    end
  end

  def handle_event("close_question", _params, socket) do
    command(socket, &Games.close_question(&1, &2))
  end

  # The position travels with the click (AD-44): it is what the screen believed
  # was current when the button was drawn, so a second click fired before the
  # re-render carries the position already left behind and the context refuses
  # it. Without it, two clicks would advance twice and skip a question.
  def handle_event("advance_question", params, socket) do
    expected = expected_position(params)

    command(socket, &Games.advance_question(&1, &2, expected))
  end

  def handle_event("open_finish", _params, socket) do
    {:noreply, assign(socket, :show_finish_modal?, true)}
  end

  def handle_event("close_finish", _params, socket) do
    {:noreply, assign(socket, :show_finish_modal?, false)}
  end

  def handle_event("confirm_finish", _params, socket) do
    socket
    |> assign(:show_finish_modal?, false)
    |> command(&Games.finish_game_session(&1, &2))
  end

  def handle_event("open_cancel", _params, socket) do
    {:noreply, assign(socket, :show_cancel_modal?, true)}
  end

  def handle_event("close_cancel", _params, socket) do
    {:noreply, assign(socket, :show_cancel_modal?, false)}
  end

  def handle_event("confirm_cancel", _params, socket) do
    socket
    |> assign(:show_cancel_modal?, false)
    |> command(&Games.cancel_game_session(&1, &2))
  end

  # The clipboard write itself is the hook's job; the server only confirms it,
  # so the host projecting the screen sees that the click did something.
  def handle_event("copy_code", _params, socket) do
    {:noreply, put_flash(socket, :info, "Código copiado")}
  end

  def handle_event("copy_link", _params, socket) do
    {:noreply, put_flash(socket, :info, "Link copiado")}
  end

  # Every command of the match is the same gesture: a screen that lost the
  # access commands nothing, the context is what judges the click, and what
  # comes back is read again instead of being patched into the assigns.
  defp command(socket, run) do
    if socket.assigns.access_lost? do
      {:noreply, socket}
    else
      %{current_scope: scope, session: session} = socket.assigns

      case run.(scope, session) do
        {:ok, %GameSession{status: :in_progress} = running} ->
          {:noreply, socket |> assign(:session, running) |> load_match()}

        {:ok, %GameSession{} = over} ->
          {:noreply, close(socket, over)}

        # A repeated click carries the position the match has already left
        # behind: refusing it is the whole point of AD-44, and the screen has
        # nothing to say about it beyond redrawing itself.
        {:error, :stale} ->
          {:noreply, load_match(socket)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, refusal(reason))}
      end
    end
  end

  # The value comes from the DOM, so it is read the way any other parameter is:
  # anything that is not a position becomes `nil`, which the context compares
  # like any other value and refuses when the match is past its first question.
  defp expected_position(%{"position" => position}) when is_binary(position) do
    case Integer.parse(position) do
      {number, ""} when number > 0 -> number
      _not_a_position -> nil
    end
  end

  defp expected_position(_params), do: nil

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
    {:noreply, socket |> assign(:session, session) |> load_lobby() |> load_match()}
  end

  def handle_info({:question_advanced, session}, socket) do
    {:noreply, socket |> assign(:session, session) |> load_match()}
  end

  def handle_info({:question_closed, session}, socket) do
    {:noreply, socket |> assign(:session, session) |> load_match()}
  end

  def handle_info({:ranking_updated, ranking}, socket),
    do: {:noreply, assign(socket, :ranking, ranking)}

  def handle_info({:question_scored, _session, _ranking}, socket), do: {:noreply, socket}

  # The one event of the match that carries no struct (AD-45): with twenty-five
  # people answering, all this screen does with it is redraw a number.
  def handle_info({:answer_submitted, _session_id, count}, socket) do
    {:noreply, assign(socket, :answers_count, count)}
  end

  def handle_info({:game_finished, session}, socket) do
    {:noreply, close(socket, session)}
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
    |> assign(:show_finish_modal?, false)
    |> load_lobby()
    |> load_match()
    |> load_final_ranking(session)
    |> load_summary()
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

      <p :if={active?(@session)} id="match-setup" class="mt-2 text-base-content/70">
        {Formatters.format_match_setup(@question_count, @session.question_duration_seconds)}
      </p>

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

      <ShareSession.share_session
        :if={waiting?(@session)}
        code={@session.join_code}
        url={@join_url}
        class="mt-8"
      />

      <section :if={started?(@session)} id="match" class="mt-8 space-y-8">
        <div
          :if={pending?(@game_state)}
          id="match-pending"
          class="rounded-2xl border border-success p-8 text-center"
        >
          <h2 class="text-4xl font-black">Pronto para começar</h2>
          <p class="mt-3 text-base-content/70">
            As inscrições estão encerradas. Avance para abrir a pergunta 1: ela já entra
            no ar aceitando respostas e o tempo começa a correr.
          </p>
        </div>

        <article
          :if={not pending?(@game_state)}
          id="current-question"
          class="rounded-2xl border border-base-300 p-6 sm:p-8"
        >
          <header class="flex flex-wrap items-center justify-between gap-4 border-b border-base-300 pb-4">
            <h2 id="question-progress" class="text-xl font-semibold">
              Pergunta {@game_state.question_number} de {@game_state.question_count}
            </h2>

            <p :if={counting?(@game_state)} class="flex items-center gap-2">
              <.icon name="hero-clock" class="size-6 text-base-content/70" />
              <span class="sr-only">Tempo restante desta pergunta:</span>
              <%!-- O id carrega a posição de propósito: a pergunta seguinte monta um
              elemento novo e o hook da anterior é destruído, em vez de seguir
              contando por cima da pergunta que entrou. --%>
              <span
                id={"question-countdown-#{@game_state.question_number}"}
                phx-hook=".Countdown"
                phx-update="ignore"
                data-ends-at={DateTime.to_iso8601(@game_state.ends_at)}
                role="timer"
                aria-live="polite"
                aria-atomic="true"
                class="font-mono text-3xl font-bold tabular-nums"
              >
                {Formatters.format_countdown(@game_state.seconds_left)}
              </span>
            </p>

            <p :if={closed?(@game_state)} id="question-closed-badge" class="text-lg text-warning">
              Pergunta encerrada
            </p>
          </header>

          <p id="question-text" class="mt-6 text-3xl font-bold break-words sm:text-4xl">
            {@game_state.question_text}
          </p>

          <ul :if={not closed?(@game_state)} id="question-options" class="mt-6 space-y-3">
            <li
              :for={option <- @game_state.options}
              id={"option-#{option.id}"}
              class={[
                "flex items-center gap-4 rounded-xl border p-4 text-xl",
                if(option.correct, do: "border-success bg-success/10", else: "border-base-300")
              ]}
            >
              <span
                aria-hidden="true"
                class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-base-200 font-bold"
              >
                {option_letter(option.position)}
              </span>

              <span class="min-w-0 break-words">{option.text}</span>

              <span
                :if={option.correct}
                class="ml-auto flex shrink-0 items-center gap-1 text-base font-semibold text-success"
              >
                <.icon name="hero-check-circle" class="size-5" /> Resposta correta
              </span>
            </li>
          </ul>

          <QuestionResults.question_results :if={@results} results={@results} viewer={:host} />

          <Ranking.ranking :if={closed?(@game_state) and @ranking} ranking={@ranking} />

          <p
            id="answers-count"
            aria-live="polite"
            class="mt-6 border-t border-base-300 pt-4 text-lg"
          >
            Respostas: <strong>{@answers_count}</strong> / {@participants_count}
          </p>
        </article>

        <div class="flex flex-col items-center gap-3">
          <div class="flex flex-wrap items-center justify-center gap-4">
            <button
              type="button"
              id="close-question"
              phx-click="close_question"
              disabled={not closable?(assigns)}
              aria-disabled={to_string(not closable?(assigns))}
              class={["btn btn-lg", not closable?(assigns) && "btn-disabled"]}
            >
              Encerrar pergunta
            </button>

            <button
              type="button"
              id="advance-question"
              phx-click="advance_question"
              phx-value-position={@game_state.question_number}
              disabled={not advanceable?(assigns)}
              aria-disabled={to_string(not advanceable?(assigns))}
              class={["btn btn-primary btn-lg", not advanceable?(assigns) && "btn-disabled"]}
            >
              Próxima pergunta
            </button>
          </div>

          <div class="flex flex-wrap items-center justify-center gap-4">
            <button
              type="button"
              id="finish-game"
              phx-click="open_finish"
              disabled={@access_lost?}
              aria-disabled={to_string(@access_lost?)}
              class={[
                "btn",
                if(last_call?(@game_state), do: "btn-success btn-lg", else: "btn-ghost"),
                @access_lost? && "btn-disabled"
              ]}
            >
              Finalizar partida
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
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".Countdown">
          export default {
            mounted() { this.start() },
            updated() { this.start() },
            destroyed() { this.stop() },
            start() {
              this.stop()
              this.endsAt = Date.parse(this.el.dataset.endsAt)
              this.draw()
              // Recomputed against the clock on every tick, never decremented:
              // a background tab has its interval throttled and would drift.
              this.timer = setInterval(() => this.draw(), 200)
            },
            stop() {
              if (this.timer) { clearInterval(this.timer); this.timer = null }
            },
            draw() {
              const left = Math.max(0, Math.ceil((this.endsAt - Date.now()) / 1000))
              const seconds = String(left % 60).padStart(2, "0")
              this.el.textContent = `${Math.floor(left / 60)}:${seconds}`
              if (left === 0) { this.stop() }
            }
          }
        </script>
      </section>

      <section :if={waiting?(@session)} class="mt-8 space-y-6">
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

      <GameOver.game_over
        :if={not active?(@session)}
        session={@session}
        summary={@summary}
        reason={@session.status}
        viewer={:host}
        ranking={@ranking}
      />

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

      <.modal
        :if={@show_finish_modal?}
        id="finish-game-modal"
        title="Finalizar esta partida?"
        on_cancel={JS.push("close_finish")}
      >
        <p class="text-base-content/70">
          A partida termina para todo mundo agora e não poderá ser retomada: as perguntas
          que ainda não foram aplicadas ficam sem resposta. Tudo o que já foi respondido
          continua registrado.
        </p>

        <:actions>
          <button type="button" phx-click="close_finish" class="btn btn-ghost">
            Continuar jogando
          </button>

          <button
            type="button"
            id="confirm-finish"
            phx-click="confirm_finish"
            phx-disable-with="Finalizando..."
            class="btn btn-success"
          >
            Sim, finalizar
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

  # Everything below reads `game_state`; none of it decides anything. Whether
  # the question is open, whether it is the last one and how many people have
  # answered are settled by the context (F3-03), and the buttons only translate
  # that into enabled and disabled — never into shown and hidden, which would
  # make the screen jump in the middle of the presentation.
  defp pending?(%{question_state: state}), do: state == :pending

  defp closed?(%{question_state: state}), do: state == :closed

  defp counting?(%{question_state: :open, ends_at: %DateTime{}}), do: true
  defp counting?(%{}), do: false

  defp closable?(%{game_state: state, access_lost?: lost?}) do
    state.question_state == :open and not lost?
  end

  defp advanceable?(%{game_state: state, access_lost?: lost?}) do
    state.question_state != :open and not state.last_question? and not lost?
  end

  # The last question, already closed: there is nothing left to advance to and
  # ending the match is the only thing left to do, so the button says so.
  defp last_call?(%{question_state: state, last_question?: last?}) do
    last? and state == :closed
  end

  # A question always freezes exactly four alternatives, so the letters the host
  # reads out loud never run past the beginning of the alphabet.
  defp option_letter(position), do: <<?A + position - 1>>

  defp hint(%{access_lost?: true}), do: nil

  defp hint(%{session: %GameSession{status: :waiting}, connected_count: 0}),
    do: "Ninguém está conectado ainda: a partida começa com pelo menos uma pessoa na sala."

  defp hint(_assigns), do: nil

  defp hint_target(assigns), do: if(hint(assigns), do: "start-hint")

  defp subtitle(%GameSession{status: :waiting}),
    do: "Compartilhe o código, acompanhe quem chega e comece quando quiser."

  defp subtitle(%GameSession{status: :in_progress}), do: "A partida está em andamento."
  defp subtitle(_session), do: "Esta sala foi encerrada."

  defp refusal(:no_connected_participants),
    do: "A partida só começa com pelo menos uma pessoa conectada"

  defp refusal(:invalid_transition), do: "Esta sala não está mais no estado necessário"
  defp refusal(:invalid_status), do: "Esta sala não está mais no estado necessário"

  defp refusal(:no_more_questions),
    do: "Esta era a última pergunta da partida: finalize para encerrar"

  defp refusal(:no_open_question), do: "Não há pergunta aberta para encerrar"
  defp refusal(_reason), do: "Não foi possível concluir a ação. Tente novamente."
end
