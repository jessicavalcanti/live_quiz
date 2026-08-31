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
        socket |> assign(:session, session) |> assign(:ended, ended_reason(session))

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
    |> load_lobby()
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
  end

  # Every screen that is no longer a lobby ignores the events of the room. It is
  # not only wasted work: the list belongs to whoever is inside, so re-reading
  # it after leaving would ask the context for something it is right to refuse,
  # and after the room ended it would replace an explanation with a list of
  # strangers.
  defp refresh(%{assigns: %{leaving?: true}} = socket), do: socket
  defp refresh(%{assigns: %{ended: reason}} = socket) when not is_nil(reason), do: socket
  defp refresh(socket), do: load_lobby(socket)

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

  # `Phoenix.Presence` publishes its raw diff on the same topic. The nudge this
  # screen reacts to is `{:presence_changed, id}`, announced right after it, so
  # the diff itself is dropped instead of costing a second read of the lobby.
  @impl true
  def handle_info(%Broadcast{event: "presence_diff"}, socket) do
    {:noreply, socket}
  end

  def handle_info({:participant_joined, _participant}, socket) do
    {:noreply, refresh(socket)}
  end

  def handle_info({:participant_left, _participant}, socket) do
    {:noreply, refresh(socket)}
  end

  def handle_info({:participant_rejoined, _participant}, socket) do
    {:noreply, refresh(socket)}
  end

  def handle_info({:presence_changed, _session_id}, socket) do
    {:noreply, refresh(socket)}
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

  def handle_info({:game_cancelled, session}, socket) do
    {:noreply, close(socket, session)}
  end

  def handle_info({:game_expired, session}, socket) do
    {:noreply, close(socket, session)}
  end

  defp close(socket, session) do
    socket
    |> assign(:session, session)
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
            <.closed_screen ended={@ended} session={@session} />
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

  defp lobby(assigns) do
    ~H"""
    <.header>
      {@session.quiz_title}
      <:subtitle>
        <span id="own-nickname">Você entrou como <strong>{@participant.nickname}</strong></span>
      </:subtitle>
    </.header>

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

    <section
      :if={@session.status == :in_progress}
      id="game-started"
      class="mt-6 rounded-2xl border border-success p-8 text-center"
    >
      <h2 class="text-3xl font-black">Partida iniciada</h2>
      <p class="mt-3 text-base-content/70">
        As perguntas chegam na próxima fase. Fique nesta tela.
      </p>
    </section>

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

  attr :ended, :atom, required: true
  attr :session, GameSession, required: true

  defp closed_screen(assigns) do
    ~H"""
    <section id="room-closed" role="status" class="py-16 text-center">
      <h1 class="text-2xl font-bold">{closed_title(@ended)}</h1>
      <p class="mt-3 text-base-content/70">{closed_message(@ended)}</p>

      <div class="mt-6">
        <.button id="back-to-join" variant="primary" navigate={~p"/join"}>
          Entrar em outra sala
        </.button>
      </div>
    </section>
    """
  end

  defp closed_title(:cancelled), do: "Sala cancelada pelo host"
  defp closed_title(:expired), do: "Sala encerrada por ausência do host"
  defp closed_title(_reason), do: "Partida encerrada"

  defp closed_message(:cancelled),
    do: "O host encerrou esta sala. Nada deu errado do seu lado: é só entrar em outra."

  defp closed_message(:expired),
    do: "O host ficou fora tempo demais e a sala foi encerrada. Você pode entrar em outra."

  defp closed_message(_reason),
    do: "Esta partida chegou ao fim. Você pode entrar em outra sala."
end
