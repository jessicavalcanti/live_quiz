defmodule LiveQuizWeb.GameSessionLive.Player do
  @moduledoc """
  The lobby of whoever entered a room, and the screen this phase spends the
  most time on.

  Waiting is most of what happens here, so the screen exists to answer three
  questions without being asked: am I in, who else is in, and is anything
  about to change. Everything it shows comes from `LiveQuiz.Games` and is
  refreshed by the events of the room topic (AD-31) — there is no polling and
  no timer.

  The address is public and the person is recognized by the credential of that
  room in the cookie, never by an account (AD-24). Without one there is nothing
  to deny: the screen sends them to `/join` with the code already filled in,
  because someone who typed a room address and has not entered yet simply
  arrived one step too early.

  Coming back is automatic. The connected mount calls `rejoin_game_session/2`,
  which is idempotent, so reloading the page, losing the network for a moment
  or walking out and coming back all land on the same participation, with the
  same nickname and the same seat, and never on a second one. Doing it in the
  disconnected mount would run the whole thing twice, so the static render is
  an explicit "entrando na sala" instead — a blank screen on a phone on a bad
  network is the one thing this screen must not be.

  The participant is registered in the presence like the host is, which is what
  feeds the connected count the host needs in order to start.

  Once the match starts this same address becomes the screen of whoever is
  playing. What it shows is `Games.game_state/2` and nothing else — where the
  match is, what the question says, when it ends and which alternative the
  server holds for this person — so the screen never decides whether the time
  is up, and the highlighted choice is always the one that was actually
  written. Answering again is how one changes one's mind (AD-41): tapping
  another alternative sends another answer and the server replaces the row, so
  there is no "cancel", and no local mark that could disagree with the
  database after a reconnection.

  The answer key never reaches here while the question is open (AD-46): it
  arrives with the reveal and not one moment before. When the question closes,
  the same place that held the alternatives shows which one was right, how the
  room answered and whether this person got it — there is no second screen and
  no navigation, because leaving this address would break the reconnection and
  the sense of one continuous match. A refusal — the question closed, the
  deadline passed — is a discreet notice and the waiting state, never a screen
  that stops responding.

  Three endings are told apart on purpose. A cancelled room, a room that
  expired for want of a host and a room whose access moved to another tab are
  three different pieces of news, and none of them is an error on the part of
  whoever is reading. The deadline of an absent host is deliberately *not*
  shown as a countdown: there is no action to take against it, and a clock
  would only manufacture anxiety.
  """
  use LiveQuizWeb, :live_view

  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.JoinCode
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Games.Presence
  alias LiveQuizWeb.Formatters
  alias LiveQuizWeb.GameOver
  alias LiveQuizWeb.GameSessionLive.MatchAssigns
  alias LiveQuizWeb.QuestionResults
  alias LiveQuizWeb.Ranking
  alias Phoenix.Socket.Broadcast

  @impl true
  def mount(%{"code" => code}, _session, socket) do
    code = JoinCode.normalize(code)
    token = Map.get(socket.assigns.participant_tokens, code)

    socket =
      socket
      |> assign(:page_title, "Sala #{code}")
      |> assign(:code, code)
      |> assign(:session, nil)
      |> assign(:participant, nil)
      |> assign(:connection_id, nil)
      |> assign(:host_connected?, true)
      |> assign(:access_lost?, false)
      |> assign(:blocked?, false)
      |> assign(:other_room_code, nil)
      |> assign(:ended, nil)
      |> assign(:leaving?, false)
      |> assign(:participants_empty?, true)
      |> assign(:connected_ids, [])
      |> assign(:question_count, 0)
      |> assign(:game_state, nil)
      |> assign(:selected_option_id, nil)
      |> assign(:results, nil)
      |> assign(:summary, nil)
      |> assign(:notice, nil)
      |> assign(:ranking, nil)
      |> assign(:result, nil)
      |> stream(:participants, [])

    cond do
      is_nil(token) -> {:ok, back_to_join(socket)}
      connected?(socket) -> {:ok, enter(socket, token)}
      true -> {:ok, socket}
    end
  end

  # The credential names the room, and the address has to agree with it. A code
  # is only unique among live rooms, so a stale credential can point at a room
  # that ended while a brand new one took its code: reviving it would put
  # somebody back into a room they never asked for.
  defp enter(socket, token) do
    expected = socket.assigns.code

    case Games.get_session_by_participant_token(token) do
      {:ok, %GameSession{join_code: ^expected} = session} -> rejoin(socket, session, token)
      _unknown_or_from_another_room -> back_to_join(socket)
    end
  end

  # The credentials of the other rooms travel along: they are the only way the
  # server can tell that a guest is still holding a live participation
  # elsewhere (AD-28), which is what "uma sala por pessoa" means for someone
  # without an account.
  defp rejoin(socket, session, token) do
    known = Map.values(socket.assigns.participant_tokens)

    case Games.rejoin_game_session(token, known_tokens: known) do
      {:ok, participant} ->
        take_part(socket, participant)

      {:error, :already_in_another_session} ->
        block(socket, session)

      {:error, :session_ended} ->
        # There is no live participation to come back to, but whoever holds the
        # credential of this room is still somebody who played it: it is what
        # authorizes reading how far the match got.
        {:ok, participant} = Games.get_participation_by_token(token)

        socket
        |> assign(:session, session)
        |> assign(:participant, participant)
        |> assign(:ended, ended_reason(session))
        |> assign(:summary, summary_for_token(session, token))
        |> load_final_data(session)

      {:error, :not_found} ->
        back_to_join(socket)
    end
  end

  # Subscribing first, claiming second: an event published between the two
  # would otherwise be lost, and the claim is the one that announces this
  # screen to everybody else. The presence follows the LiveView process, so
  # closing the tab takes it down without anybody having to say so.
  defp take_part(socket, participant) do
    session = participant.game_session

    :ok = Games.subscribe(session.id)
    {:ok, participant, connection_id} = Games.claim_participant_connection(participant)
    {:ok, _ref} = Presence.track_participant(self(), participant, connection_id)

    socket
    |> assign(:page_title, session.quiz_title)
    |> assign(:session, session)
    |> assign(:participant, participant)
    |> assign(:connection_id, connection_id)
    |> assign(:host_connected?, is_nil(session.host_disconnected_at))
    # The same number and the same duration the host is looking at: whoever is
    # already in the room is going to play exactly this (F3-07).
    |> assign(:question_count, Games.question_count(session))
    |> load_lobby()
    |> load_match()
  end

  defp block(socket, session) do
    socket
    |> assign(:session, session)
    |> assign(:blocked?, true)
    |> assign(:other_room_code, other_room_code(socket, session))
  end

  # Best effort, and only on this one refusal: the room holding the person is
  # looked up among the credentials the browser handed over. An account can be
  # held by a room whose credential this browser never saw — hosting one, for
  # instance — and then the notice stands on its own, without a shortcut.
  defp other_room_code(socket, %GameSession{id: id}) do
    Enum.find_value(socket.assigns.participant_tokens, fn {code, token} ->
      if holding_another_room?(token, id), do: code
    end)
  end

  defp holding_another_room?(token, session_id) do
    case Games.get_participant_by_token(token) do
      {:ok, %Participant{game_session_id: other_id} = participant} ->
        other_id != session_id and Participant.in_lobby?(participant)

      {:error, :not_found} ->
        false
    end
  end

  # The list is always the context's answer, never a local edit of what is on
  # screen: the person reading it sees exactly what the host sees, which is the
  # point of putting both at the same level of visibility once inside.
  defp load_lobby(socket) do
    %{session: session, participant: participant} = socket.assigns
    {:ok, participants} = Games.list_participants_with_presence(session, participant)

    socket
    |> stream(:participants, participants, reset: true)
    |> assign(:participants_empty?, participants == [])
    |> assign(:participants_count, length(participants))
    # Not shown anywhere on this screen: it is what an answer carries to the
    # context, which uses it to decide whether this was the last one missing.
    # The ids and not the count, because that decision is about which people
    # answered and not about how many.
    |> assign(:connected_ids, for(p <- participants, p.connected, do: p.id))
  end

  # The whole match in one read (F3-03), never an edit of what is on screen: a
  # reload, a reconnection, an event and a refused answer all rebuild the same
  # assigns from the database, which is why the countdown of somebody who comes
  # back is the one that is actually left and the highlighted alternative is
  # the one the server holds — never the one that was tapped.
  defp load_match(socket) do
    %{session: session, participant: participant} = socket.assigns

    if playing?(session) do
      {:ok, state} = Games.game_state(session, participant)

      settle(socket, state)
    else
      clear_match(socket)
    end
  end

  # What decides the screen is the status that came back from the database, never
  # the one the assign was holding: a match that ended between two reads is news
  # this screen learns here as well, and an answer refused by a match that is
  # already over must not leave the question on screen.
  defp settle(socket, %{status: :in_progress} = state) do
    socket
    |> assign(:game_state, state)
    |> assign(:selected_option_id, state.my_answer_option_id)
    |> load_results(state)
    |> load_ranking(state)
  end

  defp settle(socket, %{status: :waiting}), do: clear_match(socket)

  defp settle(socket, %{status: status}) do
    socket |> clear_match() |> assign(:ended, status)
  end

  defp clear_match(socket) do
    socket
    |> assign(:game_state, nil)
    |> assign(:selected_option_id, nil)
    |> assign(:results, nil)
    |> assign(:ranking, nil)
    |> assign(:notice, nil)
  end

  # Who this screen is watching as. It is the whole difference between the
  # player and the host when it comes to reading the match, which is why
  # everything else lives in `MatchAssigns`.
  defp viewer(socket), do: socket.assigns.participant

  defp load_results(socket, state), do: MatchAssigns.assign_results(socket, viewer(socket), state)

  defp load_ranking(socket, state), do: MatchAssigns.assign_ranking(socket, viewer(socket), state)

  defp load_summary(socket), do: MatchAssigns.assign_summary(socket, viewer(socket))

  # The ending screen adds the one reading that is nobody else's: what this
  # participation itself scored.
  defp load_final_data(socket, %GameSession{status: :finished} = session) do
    socket
    |> load_ranking(session)
    |> load_own_result(session)
  end

  defp load_final_data(socket, _session), do: assign(socket, ranking: nil, result: nil)

  defp load_own_result(socket, %GameSession{id: session_id}) do
    participant = viewer(socket)

    case Games.get_game_result(participant, session_id, participant.id) do
      {:ok, result} -> assign(socket, :result, result)
      {:error, :not_found} -> assign(socket, :result, nil)
    end
  end

  defp summary_for_token(%GameSession{} = session, token) do
    with {:ok, %Participant{} = participant} <- Games.get_participation_by_token(token),
         {:ok, summary} <- Games.game_summary(session, participant) do
      summary
    else
      _no_participation_to_read -> nil
    end
  end

  defp playing?(%GameSession{status: status}), do: status == :in_progress

  # Every screen that is no longer a lobby ignores the events of the room. It is
  # not only wasted work: the list belongs to whoever is inside, so re-reading
  # it after leaving would ask the context for something it is right to refuse,
  # and after the room ended it would replace an explanation with a list of
  # strangers.
  #
  # Everything else re-reads, and what it re-reads is what the event was about.
  # Every event of a room reaches every socket in it, so a room of twenty-five
  # people turns one person joining into twenty-five refreshes — and each of
  # them used to read the lobby *and* the match, half of it about something the
  # event said nothing about (R38).
  #
  # What the reads still buy is a screen that reconciles itself: whoever comes
  # back from a moment offline finds out that the question closed on the first
  # nudge of the room, instead of holding a question nobody is waiting for.
  defp refresh(socket), do: socket |> refresh_with(&load_lobby/1) |> refresh_with(&load_match/1)

  # A lobby event: who is in the room and who is connected. During a match that
  # still matters — the connected set is what decides whether an answer was the
  # last one missing — but the match itself has not moved.
  defp refresh_lobby(socket), do: refresh_with(socket, &load_lobby/1)

  # A match event: the question, the clock, the reveal. The list of people is
  # the same as it was a moment ago.
  defp refresh_match(socket), do: refresh_with(socket, &load_match/1)

  defp refresh_with(%{assigns: %{leaving?: true}} = socket, _read), do: socket

  defp refresh_with(%{assigns: %{ended: reason}} = socket, _read) when not is_nil(reason),
    do: socket

  defp refresh_with(socket, read), do: read.(socket)

  defp back_to_join(socket) do
    redirect(socket, to: ~p"/join?code=#{socket.assigns.code}")
  end

  @doc """
  Leaves the room, in two steps that are one click.

  The participation is closed here, by the context, which is what frees the
  person to enter somewhere else. The credential of this room still has to be
  dropped from the cookie, and a LiveView cannot write cookies, so the hidden
  form posts itself to `LiveQuizWeb.GameSessionController` — the same detour
  the join screen makes, in the opposite direction.
  """
  @impl true
  def handle_event("leave", _params, socket) do
    if can_leave?(socket.assigns) do
      {:ok, participant} = Games.leave_game_session(socket.assigns.participant)

      {:noreply, socket |> assign(:participant, participant) |> assign(:leaving?, true)}
    else
      {:noreply, socket}
    end
  end

  # Answering, and answering again when one changes one's mind: it is the same
  # event, because the context replaces the row instead of keeping a history
  # (AD-41) and this screen never has to model a state without an answer.
  #
  # Whether the answer arrived in time is the context's call and not this
  # screen's: a tap the assigns already know is late is stopped here only to
  # spare a pointless round trip, and every refusal becomes a notice plus the
  # waiting state — never a screen that stops responding.
  def handle_event("answer", params, socket) do
    case option_id(params) do
      {:ok, id} -> {:noreply, answer(socket, id)}
      :error -> {:noreply, socket}
    end
  end

  # The id comes from the DOM, so it is read the way any other parameter is:
  # what is not an id is not a tap this screen has anything to say about.
  defp option_id(%{"option_id" => value}) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _not_an_id -> :error
    end
  end

  defp option_id(_params), do: :error

  defp answer(socket, option_id) do
    case socket.assigns do
      %{access_lost?: true} ->
        socket

      %{leaving?: true} ->
        socket

      %{game_state: %{question_state: :open}} ->
        submit(socket, option_id)

      %{game_state: %{question_state: :closed}} ->
        assign(socket, :notice, refusal(:question_closed))

      %{game_state: _no_question_to_answer} ->
        socket
    end
  end

  # What ends up highlighted is read back from the database and never taken from
  # the click: a write that failed must not leave a mark on screen saying that
  # it worked. `connected_ids` is the room the presence is showing, and the
  # context uses it for one thing only — deciding whether this answer was the
  # last one missing.
  defp submit(socket, option_id) do
    %{participant: participant, connected_ids: connected} = socket.assigns

    case LiveQuiz.RateLimit.hit(:answer_by_participation, participant.id) do
      :ok -> record(socket, participant, option_id, connected)
      {:error, _retry_after} -> assign(socket, :notice, refusal(:rate_limited))
    end
  end

  defp record(socket, participant, option_id, connected) do
    case Games.answer_question(participant, option_id, connected) do
      {:ok, _recorded} -> socket |> assign(:notice, nil) |> load_match()
      {:error, reason} -> socket |> assign(:notice, refusal(reason)) |> load_match()
    end
  end

  # Recording an answer takes the lock of the match, so the budget is per
  # participation and never per room: one person holding the button down must
  # not be able to make the room slow for everybody playing with them (R05).
  # The match is not re-read here — nothing about it changed, and re-reading is
  # exactly the work being declined.
  defp refusal(:rate_limited),
    do: "Muitos toques seguidos. Espere um instante antes de responder de novo."

  defp refusal(:time_is_up),
    do: "O tempo desta pergunta acabou. Sua resposta não foi registrada."

  defp refusal(reason) when reason in [:question_closed, :no_open_question],
    do: "Esta pergunta foi encerrada. Aguarde a próxima."

  # Everything else — a match that ended, a participation that left, an option
  # that is not of this question — is refused by a state the screen is about to
  # re-read anyway, so it says the one thing that is still true and useful.
  defp refusal(_reason),
    do: "Não foi possível registrar a sua resposta. Toque na alternativa de novo."

  # `Phoenix.Presence` publishes its raw diff on the same topic. The nudge this
  # screen reacts to is `{:presence_changed, id}`, announced right after it, so
  # the diff itself is dropped instead of costing a second read of the lobby.
  @impl true
  def handle_info(%Broadcast{event: "presence_diff"}, socket) do
    {:noreply, socket}
  end

  def handle_info({:participant_joined, _participant}, socket) do
    {:noreply, refresh_lobby(socket)}
  end

  def handle_info({:participant_left, _participant}, socket) do
    {:noreply, refresh_lobby(socket)}
  end

  def handle_info({:participant_rejoined, _participant}, socket) do
    {:noreply, refresh_lobby(socket)}
  end

  def handle_info({:presence_changed, _session_id}, socket) do
    {:noreply, refresh_lobby(socket)}
  end

  # The claim of every connected mount lands here, this screen's own included.
  # Another connection holding *my* participation is the only reading that
  # takes this tab out of the game; anybody else's is just a lobby to re-read.
  def handle_info({:access_transferred, participant_id, connection_id}, socket) do
    if mine?(socket.assigns, participant_id) and connection_id != socket.assigns.connection_id do
      {:noreply, assign(socket, :access_lost?, true)}
    else
      {:noreply, refresh(socket)}
    end
  end

  # The host taking their own room over from another device changes nothing for
  # whoever is waiting in it.
  def handle_info({:host_access_transferred, _connection_id}, socket) do
    {:noreply, socket}
  end

  def handle_info({:host_disconnected, _expires_at}, socket) do
    {:noreply, assign(socket, :host_connected?, false)}
  end

  def handle_info({:host_connected, _expires_at}, socket) do
    {:noreply, assign(socket, :host_connected?, true)}
  end

  def handle_info({:game_started, session}, socket) do
    {:noreply, socket |> assign(:session, session) |> refresh()}
  end

  # A new question wipes the notice of the previous one: an answer that arrived
  # late is old news the moment there is something new to answer.
  def handle_info({:question_advanced, session}, socket) do
    {:noreply, socket |> assign(:session, session) |> assign(:notice, nil) |> refresh_match()}
  end

  # The three ways a question closes — the deadline, the host and the last
  # answer missing — arrive here as the same event and are read back the same
  # way, so the screen has no idea which one it was and no reason to.
  def handle_info({:question_closed, session}, socket) do
    {:noreply, socket |> assign(:session, session) |> refresh_match()}
  end

  def handle_info({:ranking_updated, ranking}, socket),
    do: {:noreply, assign(socket, :ranking, ranking)}

  # The one event of the match this screen has nothing to do with: how many
  # people have answered is the host's number, and putting it here would tell
  # whoever is still choosing how far behind the room they are.
  def handle_info({:answer_submitted, _session_id, _count}, socket) do
    {:noreply, socket}
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

  defp close(socket, session) do
    socket
    |> assign(:session, session)
    |> load_final_data(session)
    |> load_summary()
    |> assign(:ended, ended_reason(session))
  end

  defp mine?(%{participant: %Participant{id: id}}, participant_id), do: id == participant_id

  # The button is not on screen in either state, but the event can still be
  # pushed by hand: giving up a participation that already belongs to another
  # connection, or to a room that is over, is exactly what must not happen.
  defp can_leave?(%{access_lost?: true}), do: false
  defp can_leave?(%{ended: reason}) when not is_nil(reason), do: false
  defp can_leave?(_assigns), do: true

  defp ended_reason(%GameSession{} = session) do
    if GameSession.active?(session), do: nil, else: session.status
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl">
        <%= cond do %>
          <% @blocked? -> %>
            <.blocked_screen code={@code} other_room_code={@other_room_code} />
          <% @access_lost? -> %>
            <.access_lost_screen />
          <% @ended -> %>
            <GameOver.game_over
              session={@session}
              summary={@summary}
              reason={@ended}
              viewer={:player}
              ranking={@ranking}
              result={@result}
            />
          <% @game_state -> %>
            <.match
              game_state={@game_state}
              selected_option_id={@selected_option_id}
              results={@results}
              notice={@notice}
              host_connected?={@host_connected?}
              leaving?={@leaving?}
              code={@code}
              current_participant_id={@participant.id}
              ranking={@ranking}
            />
          <% @participant -> %>
            <.lobby
              session={@session}
              participant={@participant}
              participants={@streams.participants}
              participants_empty?={@participants_empty?}
              participants_count={@participants_count}
              host_connected?={@host_connected?}
              leaving?={@leaving?}
              code={@code}
              question_count={@question_count}
            />
          <% true -> %>
            <.connecting_screen code={@code} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :session, GameSession, required: true
  attr :participant, Participant, required: true
  attr :participants, :any, required: true
  attr :participants_empty?, :boolean, required: true
  attr :participants_count, :integer, required: true
  attr :host_connected?, :boolean, required: true
  attr :leaving?, :boolean, required: true
  attr :code, :string, required: true
  attr :question_count, :integer, required: true

  defp lobby(assigns) do
    ~H"""
    <.header>
      {@session.quiz_title}
      <:subtitle>
        <span id="own-nickname">Você entrou como <strong>{@participant.nickname}</strong></span>
      </:subtitle>
    </.header>

    <p id="match-setup" class="mt-2 text-base-content/70">
      {Formatters.format_match_setup(@question_count, @session.question_duration_seconds)}
    </p>

    <div id="notices" aria-live="polite" class="mt-6 space-y-4">
      <p
        :if={not @host_connected?}
        id="host-away-notice"
        class="rounded-lg border border-warning bg-warning/10 p-4 text-warning-content"
      >
        O host está desconectado. A sala continua aberta e a partida começa assim que
        ele voltar.
      </p>
    </div>

    <p
      :if={@session.status == :waiting}
      id="waiting-notice"
      class="mt-6 rounded-2xl border border-base-300 p-6 text-center text-lg"
    >
      Aguardando o host iniciar a partida…
    </p>

    <section class="mt-8 space-y-4">
      <h2 id="participants-title" class="text-lg font-semibold">
        Participantes ({@participants_count})
      </h2>

      <p :if={@participants_empty?} id="participants-empty" class="text-base-content/70">
        Ninguém mais entrou ainda.
      </p>

      <ul
        id="participants"
        aria-labelledby="participants-title"
        phx-update="stream"
        class="grid grid-cols-1 gap-3 sm:grid-cols-2"
      >
        <li
          :for={{dom_id, participant} <- @participants}
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

          <span class="min-w-0 font-medium break-words">
            {participant.nickname}<span :if={participant.id == @participant.id}>&nbsp;(você)</span>
          </span>

          <span :if={not participant.connected} class="ml-auto text-sm text-warning">
            desconectado
          </span>
        </li>
      </ul>
    </section>

    <.leave_form code={@code} leaving?={@leaving?} />
    """
  end

  attr :game_state, :map, required: true
  attr :selected_option_id, :integer, default: nil
  attr :results, :map, default: nil
  attr :notice, :string, default: nil
  attr :host_connected?, :boolean, required: true
  attr :leaving?, :boolean, required: true
  attr :code, :string, required: true
  attr :current_participant_id, :integer, required: true
  attr :ranking, :list, default: nil

  defp match(assigns) do
    ~H"""
    <div id="notices" aria-live="polite" class="space-y-4">
      <p
        :if={not @host_connected?}
        id="host-away-notice"
        class="rounded-lg border border-warning bg-warning/10 p-4 text-warning-content"
      >
        O host está desconectado. A partida continua e ele volta a qualquer momento.
      </p>

      <p
        :if={@notice}
        id="answer-notice"
        role="alert"
        class="rounded-lg border border-warning bg-warning/10 p-4 text-warning-content"
      >
        {@notice}
      </p>
    </div>

    <section
      :if={pending?(@game_state)}
      id="match-pending"
      class="mt-6 rounded-2xl border border-base-300 p-8 text-center"
    >
      <h1 class="text-2xl font-bold">A partida vai começar</h1>
      <p class="mt-3 text-base-content/70">
        Fique nesta tela: a primeira pergunta aparece aqui assim que o host abrir.
      </p>
    </section>

    <article
      :if={open?(@game_state)}
      id="current-question"
      class="mt-6 rounded-2xl border border-base-300 p-4 sm:p-6"
    >
      <header class="flex flex-wrap items-center justify-between gap-4 border-b border-base-300 pb-4">
        <h1 id="question-progress" class="text-lg font-semibold">
          Pergunta {@game_state.question_number} de {@game_state.question_count}
        </h1>

        <p class="flex items-center gap-2">
          <.icon name="hero-clock" class="size-5 text-base-content/70" />
          <span class="sr-only">Tempo restante desta pergunta:</span>
          <%!-- O id carrega a posição de propósito: a pergunta seguinte monta um
          elemento novo e o hook da anterior é destruído, em vez de seguir
          contando por cima da pergunta que entrou. --%>
          <span
            id={"question-countdown-#{@game_state.question_number}"}
            phx-hook=".Countdown"
            phx-update="ignore"
            data-ends-at={DateTime.to_iso8601(@game_state.ends_at)}
            data-server-now={DateTime.to_iso8601(@game_state.server_now)}
            role="timer"
            aria-live="polite"
            aria-atomic="true"
            class="font-mono text-2xl font-bold tabular-nums"
          >
            {Formatters.format_countdown(@game_state.seconds_left)}
          </span>
        </p>
      </header>

      <h2 id="question-text" class="mt-6 text-2xl font-bold break-words sm:text-3xl">
        {@game_state.question_text}
      </h2>

      <ul id="question-options" class="mt-6 space-y-3">
        <li :for={option <- @game_state.options}>
          <%!-- O alvo é o botão inteiro, alto o bastante para o polegar, e o
          destaque sai de `selected_option_id`, que é o que o servidor
          confirmou — nunca do toque. O `phx-click-loading` tira o botão do
          caminho enquanto o evento está no ar, para que um toque duplo não
          vire duas gravações. --%>
          <button
            type="button"
            id={"option-#{option.id}"}
            phx-click="answer"
            phx-value-option_id={option.id}
            aria-pressed={to_string(option.id == @selected_option_id)}
            class={[
              "flex w-full items-center gap-4 rounded-xl border p-4 text-left text-lg",
              "min-h-16 transition hover:border-primary [&.phx-click-loading]:pointer-events-none",
              if(option.id == @selected_option_id,
                do: "border-primary bg-primary/10 font-semibold",
                else: "border-base-300"
              )
            ]}
          >
            <span
              aria-hidden="true"
              class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-base-200 font-bold"
            >
              {Formatters.option_letter(option.position)}
            </span>

            <span class="min-w-0 break-words">{option.text}</span>

            <span
              :if={option.id == @selected_option_id}
              class="ml-auto flex shrink-0 items-center gap-1 text-sm font-semibold text-primary"
            >
              <.icon name="hero-check-circle" class="size-5" /> sua resposta
            </span>
          </button>
        </li>
      </ul>

      <p id="swap-hint" class="mt-6 border-t border-base-300 pt-4 text-base-content/70">
        Você pode trocar de alternativa até o tempo acabar.
      </p>
    </article>

    <%!-- A pergunta encerrada é o mesmo lugar da pergunta aberta, com outro
    conteúdo: navegar para outra tela quebraria a continuidade e a reconexão. A
    revelação só entra quando a apuração existe — entre o prazo vencer na tela e
    o timer encerrar de fato, o que há é a espera. --%>
    <section
      :if={answers_closed?(@game_state)}
      id="question-waiting"
      class="mt-6 rounded-2xl border border-base-300 p-6 text-center sm:p-8"
    >
      <h1 id="question-progress" class="text-lg font-semibold">
        Pergunta {@game_state.question_number} de {@game_state.question_count}
      </h1>

      <p id="question-closed-badge" class="mt-3 text-xl font-bold text-warning">
        Pergunta encerrada
      </p>

      <QuestionResults.question_results :if={@results} results={@results} viewer={:player} />

      <Ranking.ranking
        :if={@ranking}
        ranking={@ranking}
        current_participant_id={@current_participant_id}
      />

      <p class="mt-6 text-base-content/70">
        Aguarde: o host abre a próxima pergunta quando quiser.
      </p>
    </section>

    <.leave_form code={@code} leaving?={@leaving?} />

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Countdown">
      export default {
        mounted() { this.start() },
        updated() { this.start() },
        destroyed() { this.stop() },
        // O prazo e o instante em que o servidor o mediu chegam juntos, e a
        // conta é entre os dois: o relógio de quem lê nunca entra. Um navegador
        // com a hora minutos fora mostrava um tempo diferente do que o servidor
        // aceita (R40).
        start() {
          this.stop()

          const endsAt = Date.parse(this.el.dataset.endsAt)
          const serverNow = Date.parse(this.el.dataset.serverNow)

          this.remainingAtSync = endsAt - serverNow
          // Monotônico: imune a acertos de hora e a suspensão da aba, que é o
          // que faz um contador voltar no tempo quando a máquina dorme.
          this.syncedAt = performance.now()

          this.draw()
          this.timer = setInterval(() => this.draw(), 200)
        },
        stop() {
          if (this.timer) { clearInterval(this.timer); this.timer = null }
        },
        draw() {
          const elapsed = performance.now() - this.syncedAt
          const left = Math.max(0, Math.ceil((this.remainingAtSync - elapsed) / 1000))
          const seconds = String(left % 60).padStart(2, "0")
          this.el.textContent = `${Math.floor(left / 60)}:${seconds}`
          if (left === 0) { this.stop() }
        }
      }
    </script>
    """
  end

  # Where the match is was settled by the context (F3-03); these only turn it
  # into what is on display.
  #
  # The deadline takes part in the display alone, never in the ruling: whether
  # an answer arrived in time is decided by `answer_question/3` against the
  # database (AD-39). What it buys here is that somebody whose answer was
  # refused for being late — and somebody who lands on the question seconds
  # after it ran out, before the timer has closed it — reads "aguarde" instead
  # of alternatives that no longer accept anything.
  defp pending?(%{question_state: state}), do: state == :pending

  defp open?(%{question_state: :open, ends_at: %DateTime{} = ends_at}),
    do: DateTime.after?(ends_at, DateTime.utc_now())

  defp open?(%{}), do: false

  # Not the same question the host screen asks with `revealed?/1`: this one is
  # also true in the seconds between a deadline passing on screen and the timer
  # actually closing the question, which is exactly when the alternatives must
  # stop being tappable.
  defp answers_closed?(state), do: not pending?(state) and not open?(state)

  # A question always freezes exactly four alternatives, so the letters never
  # run past the beginning of the alphabet.

  attr :code, :string, required: true
  attr :leaving?, :boolean, required: true

  defp leave_form(assigns) do
    ~H"""
    <.form
      for={to_form(%{}, as: :leave)}
      id="leave-form"
      action={~p"/game-sessions/#{@code}/leave"}
      method="delete"
      phx-submit="leave"
      phx-trigger-action={@leaving?}
      class="mt-8 flex justify-end"
    >
      <button type="submit" id="leave-room" class="btn btn-ghost text-error">
        Sair da sala
      </button>
    </.form>
    """
  end

  attr :code, :string, required: true

  defp connecting_screen(assigns) do
    ~H"""
    <section id="connecting" role="status" aria-live="polite" class="py-16 text-center">
      <h1 class="text-2xl font-bold">Entrando na sala {@code}…</h1>
      <p class="mt-3 text-base-content/70">
        Estamos recuperando a sua participação. Isso leva só um instante.
      </p>
    </section>
    """
  end

  attr :code, :string, required: true
  attr :other_room_code, :string, default: nil

  defp blocked_screen(assigns) do
    ~H"""
    <section id="another-room-notice" role="alert" class="py-16 text-center">
      <h1 class="text-2xl font-bold">Você já está em outra sala</h1>
      <p class="mt-3 text-base-content/70">
        Sua participação na sala {@code} continua reservada. Saia da sala em que você
        está agora para voltar para cá.
      </p>

      <div class="mt-6">
        <.button
          :if={@other_room_code}
          id="back-to-other-room"
          variant="primary"
          navigate={~p"/game-sessions/#{@other_room_code}"}
        >
          Ir para a sala {@other_room_code}
        </.button>

        <.button
          :if={is_nil(@other_room_code)}
          id="back-to-join"
          variant="primary"
          navigate={~p"/join"}
        >
          Ir para a tela de entrada
        </.button>
      </div>
    </section>
    """
  end

  defp access_lost_screen(assigns) do
    ~H"""
    <section id="access-lost-notice" role="alert" class="py-16 text-center">
      <h1 class="text-2xl font-bold">Você abriu esta sala em outro lugar</h1>
      <p class="mt-3 text-base-content/70">
        A sua participação continua a mesma, mas agora é a outra aba que está na sala.
        Esta tela parou de acompanhar a partida.
      </p>

      <div class="mt-6">
        <.button id="back-home" variant="primary" navigate={~p"/"}>Voltar ao início</.button>
      </div>
    </section>
    """
  end
end
