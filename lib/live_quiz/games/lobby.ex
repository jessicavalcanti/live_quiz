defmodule LiveQuiz.Games.Lobby do
  @moduledoc """
  The door of a room: entering, leaving, coming back, and who may hold a seat.

  `LiveQuiz.Games` held this next to opening rooms, reading matches and closing
  them — three concerns whose only relation is that they touch the same tables
  (R41). Size alone is not a defect; what size buys is room for two answers to
  the same question to drift apart, which is how one "close" came to mean three
  different things (R10–R12) one module over.

  What lives here is one question: **may this person have a seat, and which
  one**. It has three hard parts, and they are hard together.

  **Identity without an account.** Most people who join a quiz have no account
  and never will, so the credential of the participation is who they are
  (AD-24). A guest who drops their credentials is a new person as far as the
  server can tell, which is why joining takes the tokens the client already
  holds: it is the only way to recognise somebody already sitting in another
  room (AD-28).

  **One room per person.** Enforced by the database, and checked here against
  the account *and* against every credential presented, because those are two
  different ways of being the same person.

  **A seat is taken once.** Two guests racing for the last seat, or for the
  same nickname, are settled by locks and by a unique index, in the order
  `LiveQuiz.Games.Locks` declares — never by reading first and deciding after.

  `LiveQuiz.Games` remains the façade: everything here is reachable through it
  under the name it always had, so no caller was asked to learn a new one.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Accounts.User
  alias LiveQuiz.Games
  alias LiveQuiz.Games.Access
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.JoinCode
  alias LiveQuiz.Games.Locks
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Games.ParticipantToken
  alias LiveQuiz.Games.Presence
  alias LiveQuiz.Games.Room
  alias LiveQuiz.Games.Topic
  alias LiveQuiz.Repo

  @max_participants 25
  # A client presents the credentials it holds; this is how many are looked at.
  @max_known_tokens 20

  @typedoc """
  Every way entering a room can be refused.

  Each one is a distinct atom because the web and the API word each of them
  differently, and "não foi possível entrar" would leave somebody retyping a
  nickname when the room is simply full.
  """
  @type join_error ::
          :session_not_found
          | :session_not_joinable
          | :session_full
          | :nickname_taken
          | :already_in_another_session
          | Changeset.t()

  @doc """
  Puts someone into a room identified by its code.

  `scope` is an authenticated scope or `nil` for a guest. `opts` accepts
  `:known_tokens`, the credentials the client already holds — the only way to
  recognize a guest who is already in another room (AD-28), since a guest who
  drops their credentials is a new person as far as the server can tell.

  Answers with the participation and the clear access token, which is shown
  here and nowhere else. Joining the same room again is not a new sign-up: the
  existing participation comes back, taking no extra seat, with the credential
  that was presented or with a freshly issued one when none was.

  Every refusal is a distinct atom — `:session_not_found`,
  `:session_not_joinable`, `:session_full`, `:nickname_taken`,
  `:already_in_another_session` — because the web and the API word each of them
  differently. A malformed nickname comes back as a changeset instead.
  """
  @spec join_game_session(Scope.t() | nil, term(), map(), keyword()) ::
          {:ok, Participant.t(), String.t()} | {:error, join_error()}
  def join_game_session(scope, code, attrs, opts \\ [])

  def join_game_session(scope, code, attrs, opts)
      when (is_nil(scope) or is_struct(scope, Scope)) and is_map(attrs) and is_list(opts) do
    known = known_credentials(opts)

    Repo.transaction(fn ->
      with {:ok, found} <- fetch_joinable_session(code),
           {:ok, :new} <- resolve_identity(scope, found, known),
           {:ok, session} <- lock_joinable_session(found),
           :ok <- ensure_seat_available(session),
           {:ok, participant, token} <- insert_participant(session, scope, attrs) do
        {participant, token}
      else
        {:ok, :existing, participant, token} -> {participant, token}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {participant, token}} ->
        Topic.broadcast(participant.game_session_id, {:participant_joined, participant})
        {:ok, participant, token}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Everything a room tells someone who has not entered it yet.

  Only the quiz title and whether the room still takes people (AD-35): before
  entering, nobody learns who is inside nor how many. Not even the count leaks,
  since a room that is one seat from full and a room that is empty are equally
  "available" here.

  A code that cannot exist, or a room that is over, is `{:error, :not_found}` —
  the same answer, because the two are indistinguishable from outside.
  """
  @spec preview_by_code(String.t()) ::
          {:ok, %{quiz_title: String.t(), available: boolean()}} | {:error, :not_found}
  def preview_by_code(code) do
    with {:ok, %GameSession{} = session} <- Games.get_game_session_by_code(code) do
      available = session.status == :waiting and available_slots(session) > 0

      {:ok, %{quiz_title: session.quiz_title, available: available}}
    end
  end

  @doc """
  Builds the changeset the join screen validates against while it is typed.

  It is schemaless because there is nothing to insert yet: the code still has to
  find a room and the nickname still has to survive the arbitration of the
  unique index. The rules come from `LiveQuiz.Games.JoinCode` and
  `LiveQuiz.Games.Participant`, the same ones the write path applies, so no
  screen ever restates them.

  Uniqueness is deliberately absent. Answering "available" while someone types
  would be a promise the next keystroke of another guest can break, so it is
  only ever settled by `join_game_session/4`.
  """
  @spec change_join(map()) :: Changeset.t()
  def change_join(attrs \\ %{}) do
    {%{}, %{code: :string, nickname: :string}}
    |> Changeset.cast(attrs, [:code, :nickname])
    |> Changeset.update_change(:code, &JoinCode.normalize/1)
    |> Changeset.validate_required([:code], message: "informe o código da sala")
    |> validate_code_format()
    |> Participant.validate_nickname()
  end

  defp validate_code_format(changeset) do
    Changeset.validate_change(changeset, :code, fn :code, code ->
      if JoinCode.valid_format?(code) do
        []
      else
        [code: "código inválido: são #{GameSession.join_code_length()} letras e números"]
      end
    end)
  end

  @doc """
  Fetches a participation from the clear token the client presents.

  Only participations of live rooms are returned: closing a room makes every
  credential of it useless, which is why the token needs no expiration of its
  own. An unreadable or unknown token is `{:error, :not_found}`, never an
  exception — the value comes from outside.
  """
  @spec get_participant_by_token(term()) :: {:ok, Participant.t()} | {:error, :not_found}
  def get_participant_by_token(token) do
    case ParticipantToken.hash(token) do
      {:ok, hash} -> fetch_live_participant(hash)
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Fetches a participation from the clear token, **live room or already over**.

  `get_participant_by_token/1` stops answering the moment a room ends, which is
  the right answer for anything that acts on a live participation and the wrong
  one for the door of the API: a credential whose room was cancelled is not an
  unknown credential, and refusing it there would flatten into a single `401`
  the very difference `rejoin_game_session/2` exists to report as "esta sala foi
  encerrada".

  Same guarantees as its live counterpart. The value comes from outside, so an
  unreadable or unknown token is `{:error, :not_found}` and never an exception.
  """
  @spec get_participation_by_token(term()) :: {:ok, Participant.t()} | {:error, :not_found}
  def get_participation_by_token(token) do
    case ParticipantToken.hash(token) do
      {:ok, hash} -> fetch_participant(hash)
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Fetches the participation a credential still holds **in the lobby of one room**.

  The join screen asks this before offering the form: someone who is already in
  the room has nothing left to decide, and asking for a nickname again would
  suggest a second sign-up that is never going to happen.

  Someone who walked out is found just the same, and on purpose: the seat and the
  nickname stay reserved to them (AD-27), so asking for a nickname again would
  only offer the one name this room can no longer give. Coming back through the
  lobby, which is where `rejoin_game_session/2` lives, is the only path that
  gives the participation back. A credential of another room, a dead one or none
  at all is `{:error, :not_found}`.
  """
  @spec get_participant_of_session(term(), String.t()) ::
          {:ok, Participant.t()} | {:error, :not_found}
  def get_participant_of_session(token, code) when is_binary(code) do
    with {:ok, %Participant{} = participant} <- get_participant_by_token(token),
         {:ok, %GameSession{id: id}} <- Games.get_game_session_by_code(code),
         true <- participant.game_session_id == id do
      {:ok, participant}
    else
      _elsewhere -> {:error, :not_found}
    end
  end

  def get_participant_of_session(_token, _code), do: {:error, :not_found}

  @doc """
  Fetches the room a credential belongs to, **live or already over**.

  `get_participant_by_token/1` stops answering once a room ends, which is the
  right answer for anything that acts on a participation but the wrong one for
  the lobby of the participant: someone coming back to the address of a room
  that was cancelled has to read *why* it is over, and "cancelada" and
  "encerrada por ausência" are not the same news.

  It is a read of the room only. Reviving the participation is
  `rejoin_game_session/2`, and it refuses an ended room on purpose — this
  function is what turns that refusal into a sentence.
  """
  @spec get_session_by_participant_token(term()) ::
          {:ok, GameSession.t()} | {:error, :not_found}
  def get_session_by_participant_token(token) do
    case ParticipantToken.hash(token) do
      {:ok, hash} ->
        Participant
        |> join(:inner, [p], s in assoc(p, :game_session))
        |> where([p, _s], p.access_token_hash == ^hash)
        |> select([_p, s], s)
        |> Repo.one()
        |> case do
          nil -> {:error, :not_found}
          %GameSession{} = session -> {:ok, session}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Leaves a room on purpose, which is not the same as dropping off it.

  The participation disappears from the lobby list and the person is free to
  enter another room, but the row stays: the seat is not handed back (AD-27)
  and the nickname remains reserved to whoever picked it, so a room can be full
  with fewer than #{@max_participants} people present. `left_at` and
  `released_at` are stamped together here; closing a room (F2-05) stamps only
  the second one, which is what will still tell phase 4 who was present at the
  end.

  Idempotent, and allowed on a room that is already over: leaving again, or
  leaving after the room released everybody, answers with the participation
  untouched.
  """
  @spec leave_game_session(Participant.t()) :: {:ok, Participant.t()}
  def leave_game_session(%Participant{id: id, game_session_id: session_id}) do
    at = Room.now()

    # Only the row decides. The struct that arrives may have been read before a
    # rejoin, in which case leaving on the strength of it would answer "already
    # gone" about somebody who is back; or before a previous leave, in which
    # case it would stamp the instant again and announce a second departure.
    # `left_at IS NULL` in the `WHERE` is what makes this idempotent about the
    # state the database is in rather than about the state the caller remembers
    # (R23).
    # The same condition `Participant.in_lobby?/1` states, asked of the row: a
    # participation the room already released is not somebody who walked out,
    # and stamping `left_at` on it would rewrite why they are gone.
    query =
      from p in Participant,
        where: p.id == ^id and is_nil(p.left_at) and is_nil(p.released_at),
        select: p

    result =
      Repo.transaction(fn ->
        Locks.seats(session_id)
        Repo.update_all(query, set: [left_at: at, released_at: at, updated_at: at])
      end)

    case result do
      {:ok, {1, [left]}} ->
        Topic.broadcast(left.game_session_id, {:participant_left, left})
        {:ok, left}

      {:ok, {0, _unchanged}} ->
        {:ok, Repo.get!(Participant, id)}
    end
  end

  @doc """
  Comes back to a participation that is still reserved, with or without a
  voluntary exit before it.

  Allowed while the room is waiting or already running, and refused with
  `:session_ended` once it is over — a credential dies with its room. Coming
  back is not a new sign-up: no seat is taken, the capacity is not checked
  again, and neither the nickname nor `joined_at` changes. A full room still
  takes its own people back.

  Whoever is tied to another room is refused with `:already_in_another_session`
  instead of being pulled out of it — abandoning the other room is the person's
  decision, not the server's. `opts` accepts `:known_tokens`, the credentials
  the client already holds, which is the only way to notice that a guest is
  holding a live participation somewhere else (AD-28).
  """
  @spec rejoin_game_session(String.t(), keyword()) ::
          {:ok, Participant.t()}
          | {:error, :not_found}
          | {:error, :session_ended}
          | {:error, :already_in_another_session}
  def rejoin_game_session(token, opts \\ []) when is_list(opts) do
    known = known_credentials(opts)

    Repo.transaction(fn ->
      with {:ok, found} <- fetch_participant_for_rejoin(token),
           :ok <- ensure_free_to_rejoin(found, known),
           {:ok, participant, session} <- lock_live_participation(found),
           {:ok, participant} <- restore_participation(participant, session) do
        participant
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, participant} ->
        Topic.broadcast(participant.game_session_id, {:participant_rejoined, participant})
        {:ok, participant}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Registers the connection now holding the participation and answers with the
  id it was given.

  A participation has a single live access (AD-30): the connection that claims
  it last holds it, and the previous ones find out they lost the room by
  checking their own id against `connection_current?/2`. This is an `UPDATE`
  and never an `INSERT`, so the participation, the nickname and the seat are
  the very same whether the newcomer is another tab or another device.
  """
  @spec claim_participant_connection(Participant.t()) :: {:ok, Participant.t(), Ecto.UUID.t()}
  def claim_participant_connection(%Participant{} = participant) do
    connection_id = Ecto.UUID.generate()

    participant =
      participant
      |> Participant.connection_changeset(%{connection_id: connection_id})
      |> Repo.update!()

    Topic.broadcast(
      participant.game_session_id,
      {:access_transferred, participant.id, connection_id}
    )

    {:ok, participant, connection_id}
  end

  @doc """
  Lists the participations visible in the lobby, oldest first.

  Only the host of the room or someone taking part in it may read the list
  (AD-35); anybody else gets `{:error, :unauthorized}` rather than an empty
  list, so the API can answer 403 instead of pretending the room is empty.
  `viewer` is a scope, a participation, or `nil` for a guest with no credential.

  Whoever left is left out; whoever is merely disconnected stays, because the
  seat is still theirs (AD-27).
  """
  @spec list_participants(GameSession.t(), Scope.t() | Participant.t() | nil) ::
          {:ok, [Participant.t()]} | {:error, :unauthorized}
  def list_participants(%GameSession{} = session, viewer) do
    if Access.may_read_lobby?(session, viewer) do
      {:ok, session |> lobby_participants() |> Repo.all()}
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  How many seats the room has taken: every participation ever registered in it.

  Leaving does not give the seat back and being disconnected does not either
  (AD-27), so this counts rows, not people currently present. The host does not
  take a seat — they are not a participant.
  """
  @spec reserved_slots(GameSession.t()) :: non_neg_integer()
  def reserved_slots(%GameSession{id: id}) do
    Participant
    |> where([p], p.game_session_id == ^id)
    |> Repo.aggregate(:count)
  end

  @doc "How many seats are still free, from #{@max_participants} down to 0."
  @spec available_slots(GameSession.t()) :: non_neg_integer()
  def available_slots(%GameSession{} = session) do
    max(@max_participants - reserved_slots(session), 0)
  end

  @doc """
  The nickname to offer an authenticated person in the join form.

  It is the account name, stripped of anything the nickname format refuses and
  cut to #{Participant.nickname_max_length()} characters. Picking another one
  does not rename the account. Returns `nil` for a guest, and also when nothing
  usable survives the cleanup — a suggestion that would be refused is worse
  than none.
  """
  @spec suggested_nickname(Scope.t() | nil) :: String.t() | nil
  def suggested_nickname(nil), do: nil
  def suggested_nickname(%Scope{user: %User{name: name}}), do: sanitize_nickname(name)

  @doc "How many participations a room accepts. There is no waiting list."
  @spec max_participants() :: pos_integer()
  def max_participants, do: @max_participants

  @doc """
  The lobby list of `list_participants/2` with the virtual field `connected`
  filled in from the presence.

  Same authorization: only the host or someone taking part in the room may read
  it. Being disconnected keeps the person on the list — the seat is still
  theirs (AD-27) — while leaving takes them off it, connected or not.
  """
  @spec list_participants_with_presence(GameSession.t(), Scope.t() | Participant.t() | nil) ::
          {:ok, [Participant.t()]} | {:error, :unauthorized}
  def list_participants_with_presence(%GameSession{} = session, viewer) do
    with {:ok, participants} <- list_participants(session, viewer) do
      connected = Presence.connected_participant_ids(session.id)

      {:ok, Enum.map(participants, &%{&1 | connected: MapSet.member?(connected, &1.id)})}
    end
  end

  defp fetch_joinable_session(code) do
    case Games.get_game_session_by_code(code) do
      {:ok, %GameSession{status: :waiting} = session} -> {:ok, session}
      {:ok, %GameSession{}} -> {:error, :session_not_joinable}
      {:error, :not_found} -> {:error, :session_not_found}
    end
  end

  # Answers `{:ok, :new}` when the person is free to sign up, or hands back the
  # participation they already hold in this very room. The identity lock is
  # taken before any read, so two tabs of the same account cannot both conclude
  # they are free.
  defp resolve_identity(%Scope{} = scope, %GameSession{id: session_id}, known) do
    Locks.identity(scope.user.id)

    if Room.hosting?(scope.user.id) do
      {:error, :already_in_another_session}
    else
      case active_participation_for_user(scope) do
        nil -> {:ok, :new}
        %Participant{game_session_id: ^session_id} = participant -> rejoin(participant, known)
        %Participant{} -> {:error, :already_in_another_session}
      end
    end
  end

  defp resolve_identity(nil, %GameSession{id: session_id}, known) do
    participations = known |> Enum.map(&elem(&1, 0)) |> active_participations_for_hashes()

    case Enum.find(participations, &(&1.game_session_id == session_id)) do
      %Participant{} = participant -> rejoin(participant, known)
      nil when participations == [] -> {:ok, :new}
      nil -> {:error, :already_in_another_session}
    end
  end

  # Coming back to the same room reuses the credential that was presented. When
  # none was — an authenticated person on a new device — a fresh token is issued
  # and the previous one stops working, which is the single-holder rule of AD-30.
  defp rejoin(%Participant{} = participant, known) do
    case Enum.find(known, fn {hash, _token} -> hash == participant.access_token_hash end) do
      {_hash, token} ->
        {:ok, :existing, participant, token}

      nil ->
        {token, hash} = ParticipantToken.build()

        case participant |> Participant.credential_changeset(hash) |> Repo.update() do
          {:ok, participant} -> {:ok, :existing, participant, token}
          {:error, %Changeset{} = changeset} -> {:error, changeset}
        end
    end
  end

  # The room was read before any lock was held, to find out whether the code
  # even exists. By the time the seats lock is granted the host may have started
  # or cancelled it, so the row is read again — under the lock that the ending
  # of a room also takes — and judged again. Inserting on the strength of the
  # first read is how somebody ended up seated in a room that was already over
  # (R16).
  defp lock_joinable_session(%GameSession{id: id}) do
    Locks.seats(id)

    case Repo.get(GameSession, id) do
      %GameSession{status: :waiting} = session -> {:ok, session}
      %GameSession{} -> {:error, :session_not_joinable}
      nil -> {:error, :session_not_found}
    end
  end

  defp ensure_seat_available(%GameSession{} = session) do
    if reserved_slots(session) < @max_participants do
      :ok
    else
      {:error, :session_full}
    end
  end

  defp insert_participant(%GameSession{} = session, scope, attrs) do
    {token, hash} = ParticipantToken.build()

    %Participant{
      game_session_id: session.id,
      user_id: scope && scope.user.id,
      access_token_hash: hash,
      joined_at: Room.now()
    }
    |> Participant.join_changeset(attrs)
    # A refused insert would poison the surrounding transaction before the
    # constraint could be read back as an atom, so it gets its own savepoint.
    |> Repo.insert(mode: :savepoint)
    |> case do
      {:ok, %Participant{} = participant} -> {:ok, participant, token}
      {:error, %Changeset{} = changeset} -> {:error, join_error(changeset)}
    end
  end

  defp join_error(%Changeset{} = changeset) do
    cond do
      Room.unique_violation?(changeset, :nickname) -> :nickname_taken
      Room.unique_violation?(changeset, :user_id) -> :already_in_another_session
      true -> changeset
    end
  end

  defp known_credentials(opts) do
    opts
    |> Keyword.get(:known_tokens, [])
    |> List.wrap()
    |> Enum.take(@max_known_tokens)
    |> Enum.flat_map(fn token ->
      case ParticipantToken.hash(token) do
        {:ok, hash} -> [{hash, token}]
        :error -> []
      end
    end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp active_participation_for_user(%Scope{} = scope) do
    Participant
    |> where([p], p.user_id == ^scope.user.id and is_nil(p.released_at))
    |> Repo.one()
  end

  defp active_participations_for_hashes([]), do: []

  defp active_participations_for_hashes(hashes) do
    Participant
    |> where([p], p.access_token_hash in ^hashes and is_nil(p.released_at))
    |> Repo.all()
  end

  defp fetch_participant(hash) do
    Participant
    |> where([p], p.access_token_hash == ^hash)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      %Participant{} = participant -> {:ok, participant}
    end
  end

  defp fetch_live_participant(hash) do
    Participant
    |> join(:inner, [p], s in assoc(p, :game_session))
    |> where([p, s], p.access_token_hash == ^hash)
    |> where([_p, s], s.status in ^GameSession.active_statuses())
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      %Participant{} = participant -> {:ok, participant}
    end
  end

  # Unlike `get_participant_by_token/1`, this one looks past the room being over:
  # the difference between a credential nobody ever issued and one whose room is
  # closed is exactly what tells `:not_found` from `:session_ended`.
  defp fetch_participant_for_rejoin(token) do
    case ParticipantToken.hash(token) do
      {:ok, hash} ->
        Participant
        |> where([p], p.access_token_hash == ^hash)
        |> preload(:game_session)
        |> Repo.one()
        |> case do
          nil -> {:error, :not_found}
          %Participant{} = participant -> {:ok, participant}
        end

      :error ->
        {:error, :not_found}
    end
  end

  # Identity is settled first, under the identity lock, which is the order this
  # module fixes; only then is the room locked and both rows read again. The
  # room read at the top came off an unlocked `preload`, and a room that ended
  # in between would otherwise take somebody back into a match that is over —
  # or race the release that ends it (R16).
  defp lock_live_participation(%Participant{id: id, game_session_id: session_id}) do
    Locks.seats(session_id)

    session = Repo.get(GameSession, session_id)

    cond do
      is_nil(session) -> {:error, :not_found}
      not GameSession.active?(session) -> {:error, :session_ended}
      true -> {:ok, %{Repo.get!(Participant, id) | game_session: session}, session}
    end
  end

  # Nothing else may be holding the person when they come back. For an account
  # the database answers it, under the very same identity lock the join takes
  # and before any other lock, so the two orders match and cannot deadlock. A
  # guest has no identity to lock on: the only other rooms the server can tie
  # them to are the ones whose credentials the client hands over (AD-28).
  defp ensure_free_to_rejoin(%Participant{user_id: nil} = participant, known) do
    engaged_elsewhere? =
      known
      |> Enum.map(&elem(&1, 0))
      |> Enum.reject(&(&1 == participant.access_token_hash))
      |> active_participations_for_hashes()
      |> Enum.any?(&(&1.game_session_id != participant.game_session_id))

    if engaged_elsewhere?, do: {:error, :already_in_another_session}, else: :ok
  end

  defp ensure_free_to_rejoin(%Participant{user_id: user_id} = participant, _known) do
    Locks.identity(user_id)

    if Room.hosting?(user_id) or participating_elsewhere?(participant) do
      {:error, :already_in_another_session}
    else
      :ok
    end
  end

  defp restore_participation(
         %Participant{left_at: nil, released_at: nil} = participant,
         %GameSession{}
       ) do
    {:ok, participant}
  end

  defp restore_participation(%Participant{} = participant, %GameSession{} = session) do
    participant
    |> Participant.connection_changeset(%{left_at: nil, released_at: nil})
    # Clearing `released_at` puts the row back into the one-room-per-account
    # index, and the check above is only the first line of defence, so the
    # update takes its own savepoint and the violation is read back as the same
    # refusal instead of leaking a changeset.
    |> Repo.update(mode: :savepoint)
    |> case do
      {:ok, %Participant{} = restored} -> {:ok, %{restored | game_session: session}}
      {:error, %Changeset{}} -> {:error, :already_in_another_session}
    end
  end

  defp participating_elsewhere?(%Participant{id: id, user_id: user_id}) do
    Participant
    |> where([p], p.user_id == ^user_id and is_nil(p.released_at) and p.id != ^id)
    |> Repo.exists?()
  end

  defp lobby_participants(%GameSession{id: session_id}) do
    from p in Participant,
      where: p.game_session_id == ^session_id,
      where: is_nil(p.left_at) and is_nil(p.released_at),
      order_by: [asc: p.joined_at, asc: p.id]
  end

  defp sanitize_nickname(name) when is_binary(name) do
    suggestion =
      name
      |> String.replace(~r/[^\p{L}\p{N} _-]/u, "")
      |> String.trim()
      |> String.slice(0, Participant.nickname_max_length())
      |> String.trim()

    if String.length(suggestion) >= Participant.nickname_min_length(), do: suggestion
  end

  defp sanitize_nickname(_name), do: nil
end
