defmodule LiveQuiz.Games do
  @moduledoc """
  Business rules for the rooms a host opens from a quiz.

  A room is created from a quiz the caller owns and carries a join code the
  host reads out loud. Two rules decide who may open one, and both cross tables
  that no single index can cover: a person keeps **one live room at a time**,
  and someone already taking part in another room may not host at all. They are
  checked inside a transaction guarded by `pg_advisory_xact_lock/2` on the
  caller's account, so two browser tabs of the same person are serialized
  without ever blocking anybody else.

  Reads by the host take a `LiveQuiz.Accounts.Scope` and filter by owner inside
  the query: a room someone else hosts is indistinguishable from a room that
  does not exist. The lookup people use to enter a room, `get_game_session_by_code/1`,
  is deliberately unscoped — the code is the credential — and only ever answers
  with live rooms.

  Entering a room, leaving it, coming back and holding a seat live in
  `LiveQuiz.Games.Lobby`, which this context delegates to (R41). It is one
  question — may this person have a seat, and which one — with three hard parts
  that are hard together: identity without an account, one room per person, and
  a seat taken exactly once. Nothing there is settled optimistically: the
  nickname is arbitrated by a unique index, the seats are counted under an
  advisory lock on the room, and "one room per person" is serialized by an
  advisory lock on the account, always in the order `LiveQuiz.Games.Locks`
  declares.

  A room ends in one of three ways, and all of them are ordinary state
  transitions rather than deletions: the host starts it, plays it through and
  finishes it, the host cancels it, or it expires because the host stayed
  away. `cancelled` and `expired` are kept apart so the lobby can say which one
  happened. Every transition is a single `UPDATE` guarded by the status it is
  allowed to come from, checked by the number of rows it touched — never a read
  followed by a write — so a host cancelling at the very second the deadline
  runs out ends with one winner and one status. Closing is terminal: there is no
  reopening, and playing again means a new room with a new code.

  Starting a room is also the instant its content stops being a moving target:
  the questions, the options and the answer key are copied into the match and
  the status flips in a single transaction (AD-36). From there on the match is
  self-contained — every read of what is being played goes to
  `list_snapshot_questions/1` and its neighbours, never to `LiveQuiz.Quizzes` —
  so editing or deleting the quiz afterwards cannot rewrite history.

  From there the match only goes forward. `advance_question/3` opens the next
  question — never a chosen one, never a previous one (AD-44) —
  `close_question/2` reveals the answer key, and `finish_game_session/2` ends
  the match when the host says so, not when the questions run out. Which
  question is being played and whether it is still taking answers are derived
  from columns of the room rather than from an enum of their own (AD-37), and
  the deadline is absolute and written by the server (AD-39), so a screen that
  reconnects rebuilds everything from one `game_state/2` and no state ever
  lives only in memory. Each of the three commands takes an advisory lock on
  the room, which is what makes a double click a `:stale` answer instead of a
  skipped question.

  Answering is the other half of that movement, and the only command of a match
  that is not the host's. `answer_question/3` keeps a single row per
  participation and question and writes it with an upsert (AD-41), so changing
  one's mind while the question is open replaces the choice instead of piling
  another one on top, and two taps in the same instant cannot become two
  answers. That same transaction is where the question closes when the answers
  reach the number of people connected (AD-42), which is what keeps twenty-five
  simultaneous taps from closing it twice.

  The deadline of a question is the one thing here nobody has to ask for. It is
  written into `current_question_ends_at` when the question opens and enforced
  by `close_question_by_timeout/1`, which takes no scope because the caller is
  the system — `LiveQuiz.Games.QuestionTimer`, one process per match (AD-40),
  supervised outside this module. Closing by the deadline, by the host and by
  everybody having answered all end in the same columns and the same event, and
  all three are idempotent, so they may happen at the same instant and still
  reveal the answer once.

  The expiration deadline is persisted in `expires_at` (AD-23) instead of living
  in a timer, so it survives a restart without being forgotten or renewed.
  `LiveQuiz.Games` only supplies the transitions; noticing that the host dropped
  and running the sweep are F2-06's job.

  Leaving a room, coming back to it and handing its access over are three
  different things, and only the first takes the participation off the lobby
  list: `leave_game_session/1` frees the person for another room while the seat
  and the nickname stay reserved, `rejoin_game_session/2` gives that very
  participation back, and `claim_participant_connection/1` — like
  `claim_host_connection/2` for the host — only moves the live access from one
  connection to another, always with an `UPDATE` and never with an `INSERT`.

  When a question ends, `question_results/3` is what everybody reads: the frozen
  answer key, how many people picked each alternative and how many picked none.
  It is recomputed on every reading rather than persisted — the numbers are a
  couple of aggregates — and it refuses a question that has not ended, so the
  key cannot leak through a screen or an endpoint that asks too early.
  `game_summary/2` closes the match with the same reading: how far it got and
  how much was answered.

  Scoring is the other half of a question ending, and unlike those two it is
  written down. `score_closed_question/2` consolidates every last answer into
  the participation's running metrics — a correct answer is worth up to a
  thousand points, in proportion to the clock it had left — and publishes
  `{:ranking_updated, ranking}`. All three ways a question closes go through it,
  it is guarded by a persisted marker, and calling it again gives the same
  ranking back without counting anything twice. `finish_game_session/2` then
  freezes the whole thing into `LiveQuiz.Games.GameResult`, one immutable row
  per participation, which is what the history and the ending screens read.

  Everything a room does is announced on `topic/1` after the transaction that
  did it has committed (AD-31): a subscriber woken by `{:participant_joined, p}`
  that reads the database has to find the participation there. Events are
  tuples carrying structs, so a subscriber pattern matches them and the
  compiler has something to complain about when one of them changes. Nothing
  outside this module publishes them.

  ## Events of a running match

  All of them travel on the room's single topic, the same one the lobby of
  phase 2 uses (AD-45); the execution adds no topic of its own.

  ### The lobby

  | Event | Published by |
  |---|---|
  | `{:participant_joined, %Participant{}}` | `join_game_session/4` |
  | `{:participant_left, %Participant{}}` | `leave_game_session/1` |
  | `{:participant_rejoined, %Participant{}}` | `rejoin_game_session/2` |
  | `{:access_transferred, participant_id, connection_id}` | `claim_participant_connection/1` |
  | `{:host_access_transferred, connection_id}` | `claim_host_connection/2` |
  | `{:host_disconnected, expires_at}` | `record_host_absence/2` |
  | `{:host_connected, nil}` | `record_host_return/1` |

  ### The match

  | Event | Published by |
  |---|---|
  | `{:game_started, %GameSession{}}` | `start_game_session/3` |
  | `{:question_advanced, %GameSession{}}` | `advance_question/3` |
  | `{:answer_submitted, session_id, count}` | `answer_question/3` |
  | `{:question_closed, %GameSession{}}` | `close_question/2`, `close_question_by_timeout/1` and `answer_question/3` |
  | `{:ranking_updated, ranking}` | `score_closed_question/2` |
  | `{:game_finished, %GameSession{}}` | `finish_game_session/2` |
  | `{:game_cancelled, %GameSession{}}` | `cancel_game_session/2` |
  | `{:game_expired, %GameSession{}}` | `expire_game_session/1` |

  `{:answer_submitted, session_id, count}` is the one event of the match that
  carries no struct: with twenty-five people answering, every answer wakes
  twenty-six screens, and the only thing any of them does with it is redraw a
  number (AD-45). It is published for a swap too — the count does not move, but
  a screen that missed the previous message still gets the right total.

  ## Test seam

  `:join_code_generator` in the `:live_quiz` application environment replaces
  the code generator with a zero-arity function, which is how the collision
  retry is exercised. It is unset everywhere but in those tests.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Changeset
  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.History
  alias LiveQuiz.Games.JoinCode
  alias LiveQuiz.Games.Lobby
  alias LiveQuiz.Games.Locks
  alias LiveQuiz.Games.Match
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Games.QuestionTimer
  alias LiveQuiz.Games.QuizLock
  alias LiveQuiz.Games.Room
  alias LiveQuiz.Games.Scoring
  alias LiveQuiz.Games.Topic
  alias LiveQuiz.Quizzes
  alias LiveQuiz.Quizzes.Quiz
  alias LiveQuiz.Repo

  # How long a room outlives the host being away, in seconds. It is a domain
  # constant rather than a configuration knob: the lobby countdown, the
  # persisted `expires_at` and the sweeper of F2-06 all have to agree on it.
  @host_absence_timeout 300
  # `known_tokens` comes from the client, so the list is bounded before it turns
  # into a query and malformed values are dropped without an error.
  @typedoc "Every way entering a room can be refused. Defined by `LiveQuiz.Games.Lobby`."
  @type join_error :: Lobby.join_error()

  @doc """
  Opens a room for the given quiz, hosted by the scope user.

  The quiz must belong to the scope and have at least one question. The user
  must neither host another live room nor be taking part in one.

  `attrs` accepts `question_duration_seconds` — 10, 20, 30 or 60, defaulting to
  30. It is chosen here rather than at the start (AD-38) so the lobby can already
  announce the pace to whoever walks in, and it stops being changeable once the
  match begins.

  Raises `Ecto.NoResultsError` when the quiz does not exist or belongs to
  somebody else, which the callers turn into a 404.
  """
  @spec create_game_session(Scope.t(), integer() | String.t(), map()) ::
          {:ok, GameSession.t()}
          | {:error, :quiz_not_playable}
          | {:error, :host_already_in_session}
          | {:error, :already_participating}
          | {:error, :code_generation_failed}
          | {:error, Changeset.t()}

  ## Scoring
  #
  # What a closed question is worth and the standing it produces belong to
  # `LiveQuiz.Games.Scoring`. The transitions that end a question — the host
  # closing it, the deadline, everybody having answered, advancing past it and
  # finishing the match — consolidate it with `consolidate_question/2` inside
  # their own transaction, and publish what it produced once that transaction
  # commits. The rest is delegated so that callers still have one address to
  # know.

  defdelegate calculate_answer_score(answer, question, session), to: Scoring
  defdelegate score_closed_question(session, question_position), to: Scoring
  defdelegate current_ranking(session, viewer), to: Scoring
  defdelegate publish_ranking(game_session_id, ranking), to: Scoring
  ## History
  #
  # A finished match stops being the business of this module and becomes a row
  # in `LiveQuiz.Games.History`, which is where the reading rules of a result
  # live. The delegations keep `LiveQuiz.Games` the one address callers need to
  # know: no controller, LiveView or test had to change when the code moved.

  defdelegate get_game_result(identity, session_id, participant_id), to: History
  defdelegate get_my_game_result(scope, id), to: History
  defdelegate get_my_game_result_for_session(scope, session_id), to: History
  defdelegate list_game_results(scope, filters, pagination), to: History
  defdelegate list_game_result_summaries(scope, filters, pagination), to: History
  defdelegate list_quiz_game_history(scope, quiz_id, filters, pagination), to: History
  defdelegate list_host_game_history(scope, filters, pagination), to: History
  defdelegate get_host_game_history(scope, id), to: History
  defdelegate get_host_game_result(scope, id), to: History
  ## The match
  #
  # Everything a room does while it is being played belongs to
  # `LiveQuiz.Games.Match`: starting it, moving through the questions, taking the
  # answers and ending it. What stays here is the room around the match — opening
  # it, entering it, leaving it and closing it.

  defdelegate start_game_session(scope, session, connected_count), to: Match
  defdelegate list_snapshot_questions(session), to: Match
  defdelegate get_snapshot_question(session, position), to: Match
  defdelegate snapshot_question_count(session), to: Match
  defdelegate question_count(session), to: Match
  defdelegate advance_question(scope, session, expected_position), to: Match
  defdelegate advance_question(scope, session, expected_position, opts), to: Match
  defdelegate close_question(scope, session), to: Match
  defdelegate close_question(scope, session, opts), to: Match
  defdelegate close_question_by_timeout(session_id), to: Match
  defdelegate close_question_by_timeout(session_id, expected_position), to: Match
  defdelegate list_sessions_with_open_question(), to: Match
  defdelegate get_session_for_timeout(session_id), to: Match
  defdelegate answer_question(participant, answer_option_id, connected_ids), to: Match
  defdelegate current_answers_count(session), to: Match
  defdelegate finish_game_session(scope, session), to: Match
  defdelegate finish_game_session(scope, session, opts), to: Match
  defdelegate game_state(session, viewer), to: Match
  defdelegate question_results(session, position, viewer), to: Match
  defdelegate game_summary(session, viewer), to: Match

  def create_game_session(scope, quiz_id, attrs \\ %{})

  def create_game_session(%Scope{} = scope, quiz_id, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      Locks.identity(scope.user.id)
      # The id is resolved through the scope first, so somebody else's quiz is a
      # 404 before anything is locked. What the room is then built from is the
      # row read back *after* the lock: an edit already under way finishes
      # first, and the title and the questions this reads are the ones that
      # survived it. Validating the copy read before the lock would let an edit
      # that removed the last question slip a room in behind it (R24).
      %Quiz{id: id} = Quizzes.get_quiz!(scope, quiz_id)
      QuizLock.lock_quiz!(id)
      quiz = Quizzes.get_quiz!(scope, id)

      with :ok <- Room.ensure_playable(quiz),
           :ok <- ensure_not_hosting(scope),
           :ok <- ensure_not_participating(scope),
           {:ok, session} <-
             insert_with_join_code(scope, quiz, attrs, JoinCode.max_attempts()) do
        session
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Builds the changeset the "abrir sala" form is drawn from.

  The duration is the only thing the host chooses when opening a room (AD-38),
  so the form has a single field, already carrying the default of 30 seconds.
  The screen never restates which durations are allowed: it asks
  `LiveQuiz.Games.GameSession.question_durations/0` for the list and hands the
  submission straight back to `create_game_session/3`, whose changeset is the
  one that refuses anything else.
  """
  @spec change_question_duration(map()) :: Changeset.t()
  def change_question_duration(attrs \\ %{}) do
    GameSession.duration_changeset(%GameSession{}, attrs)
  end

  @doc """
  Fetches a **live** room by its code, without a scope, trimming and upcasing
  the value first so a code typed in lowercase still works.

  A code that cannot exist is rejected before any query runs. Rooms that are
  over are never returned: a cancelled or expired room is not reopened, and its
  code is free for a new room to take.
  """
  @spec get_game_session_by_code(String.t()) :: {:ok, GameSession.t()} | {:error, :not_found}
  def get_game_session_by_code(code) when is_binary(code) do
    normalized = JoinCode.normalize(code)

    if JoinCode.valid_format?(normalized) do
      GameSession
      |> where([s], s.join_code == ^normalized)
      |> Room.live()
      |> Repo.one()
      |> case do
        nil -> {:error, :not_found}
        %GameSession{} = session -> {:ok, session}
      end
    else
      {:error, :not_found}
    end
  end

  def get_game_session_by_code(_code), do: {:error, :not_found}

  @doc """
  Fetches a room of the scope user by its code, live **or already over**.

  The lobby of the host is addressed by code rather than by id (F2-08), and it
  has to keep answering after the room ends: a host who comes back to the
  address has to read that the room was cancelled or that it expired, instead
  of a 404 that says nothing. Because a code is only unique among live rooms,
  the same host may hold several closed rooms with it — the most recent one is
  the one the address means.

  The owner filter is in the query, so a room somebody else hosts is
  indistinguishable from a room that never existed: both raise
  `Ecto.NoResultsError`, which the callers turn into a 404. A value that is not
  shaped like a code finds nothing and ends the same way.
  """
  @spec get_hosted_session_by_code!(Scope.t(), String.t()) :: GameSession.t()
  def get_hosted_session_by_code!(%Scope{} = scope, code) when is_binary(code) do
    normalized = JoinCode.normalize(code)

    scope
    |> Room.hosted()
    |> where([s], s.join_code == ^normalized)
    |> order_by([s], desc: s.inserted_at, desc: s.id)
    |> limit(1)
    |> Repo.one!()
  end

  @doc """
  Fetches a match by its code, **live or already over**, with no owner filter.

  The reads of phase 2 do not serve the execution. `get_game_session_by_code/1`
  stops answering the moment a room ends, which would turn a command sent to a
  cancelled match into "no such room" instead of "this match is over", and
  `get_hosted_session_by_code!/2` filters by owner, which would answer a stranger
  with the 404 of AD-10 rather than letting the command refuse them. Executing a
  match needs neither: the room is found first and **the command that follows is
  what decides who may run it** (AD-46), so the refusal comes from the context
  and reads the same on the web and on the API.

  A code is only unique among live rooms, so several rooms that are over may
  share one; the most recent is the one the address means, exactly as the lobby
  of the host resolves it. A value that is not shaped like a code finds nothing.
  """
  @spec get_match_by_code(String.t()) :: {:ok, GameSession.t()} | {:error, :not_found}
  def get_match_by_code(code) when is_binary(code) do
    normalized = JoinCode.normalize(code)

    if JoinCode.valid_format?(normalized) do
      GameSession
      |> where([s], s.join_code == ^normalized)
      |> order_by([s], desc: s.inserted_at, desc: s.id)
      |> limit(1)
      |> Repo.one()
      |> case do
        nil -> {:error, :not_found}
        %GameSession{} = session -> {:ok, session}
      end
    else
      {:error, :not_found}
    end
  end

  def get_match_by_code(_code), do: {:error, :not_found}

  @doc """
  Fetches a room by the identifier that is only ever about that room.

  The join code is reusable once a room is over, so an address built from it
  answers about whatever room holds it now. `public_id` is issued once and never
  reused, which is what a link kept from a finished match needs (R29).
  """
  @spec get_match_by_public_id(String.t()) :: {:ok, GameSession.t()} | {:error, :not_found}
  def get_match_by_public_id(public_id) when is_binary(public_id) do
    case Ecto.UUID.cast(public_id) do
      {:ok, uuid} -> fetch_by_public_id(uuid)
      :error -> {:error, :not_found}
    end
  end

  def get_match_by_public_id(_public_id), do: {:error, :not_found}

  @doc """
  Fetches a room from a durable address, which may be either identifier.

  A `public_id` names one room forever; a join code names the most recent room
  that holds it, which is what every address written before public ids existed
  carries. Telling them apart is a matter of shape, so both keep working and
  only one of them is ambiguous.
  """
  @spec get_match_by_reference(String.t()) :: {:ok, GameSession.t()} | {:error, :not_found}
  def get_match_by_reference(reference) when is_binary(reference) do
    case get_match_by_public_id(reference) do
      {:ok, session} -> {:ok, session}
      {:error, :not_found} -> get_match_by_code(reference)
    end
  end

  def get_match_by_reference(_reference), do: {:error, :not_found}

  defp fetch_by_public_id(uuid) do
    case Repo.get_by(GameSession, public_id: uuid) do
      nil -> {:error, :not_found}
      %GameSession{} = session -> {:ok, session}
    end
  end

  @doc "Returns the live room hosted by the scope user, if there is one."
  @spec get_active_session_for_host(Scope.t()) :: GameSession.t() | nil
  def get_active_session_for_host(%Scope{} = scope) do
    scope
    |> Room.hosted()
    |> Room.live()
    |> Repo.one()
  end

  @doc """
  Tells whether the scope user is tied to any room, hosting or taking part in it.

  Someone who left a room but was not released yet still counts: the seat is
  theirs until the room lets it go (AD-27).

  The screens ask `get_active_session_for_host/1` instead, which answers with
  the room rather than with a boolean; this is the seam the tests of leaving,
  of being released and of the one-room rule use to observe the answer without
  reaching into two tables themselves.
  """
  @spec engaged_in_session?(Scope.t()) :: boolean()
  def engaged_in_session?(%Scope{} = scope) do
    hosting?(scope) or participating?(scope)
  end

  ## The lobby
  #
  # Entering a room, leaving it, coming back, and who may hold a seat, all live
  # in `LiveQuiz.Games.Lobby` — one question with three hard parts, kept
  # together instead of next to opening rooms and closing them (R41). This
  # context stays the façade, so nothing outside it had to learn a new name;
  # the documentation of each function is where the function is.

  defdelegate join_game_session(scope, code, attrs, opts \\ []), to: Lobby
  defdelegate preview_by_code(code), to: Lobby
  defdelegate change_join(attrs \\ %{}), to: Lobby
  defdelegate get_participant_by_token(token), to: Lobby
  defdelegate get_participation_by_token(token), to: Lobby
  defdelegate get_participant_of_session(token, code), to: Lobby
  defdelegate get_session_by_participant_token(token), to: Lobby
  defdelegate leave_game_session(participant), to: Lobby
  defdelegate rejoin_game_session(token, opts \\ []), to: Lobby
  defdelegate claim_participant_connection(participant), to: Lobby

  ## Seats

  defdelegate list_participants(session, viewer), to: Lobby
  defdelegate list_participants_with_presence(session, viewer), to: Lobby
  defdelegate reserved_slots(session), to: Lobby
  defdelegate available_slots(session), to: Lobby
  defdelegate suggested_nickname(scope), to: Lobby
  defdelegate max_participants(), to: Lobby

  @doc """
  The same access transfer, applied to the host of a room.

  Another tab or another device takes the room over and the connection that
  held it stops being the host's. Losing the room does **not** end the account
  session of the previous device: what changes hands is the access to this
  room, nothing else.

  The room is read back through the scope, so somebody who does not host it
  gets `:unauthorized` instead of taking it over.
  """
  @spec claim_host_connection(Scope.t(), GameSession.t()) ::
          {:ok, GameSession.t(), Ecto.UUID.t()} | {:error, :unauthorized}
  def claim_host_connection(%Scope{} = scope, %GameSession{} = session) do
    case Room.fetch_hosted(scope, session) do
      {:error, :unauthorized} = error ->
        error

      {:ok, session} ->
        connection_id = Ecto.UUID.generate()

        session =
          session
          |> GameSession.host_presence_changeset(%{host_connection_id: connection_id})
          |> Repo.update!()

        Topic.broadcast(session.id, {:host_access_transferred, connection_id})

        {:ok, session, connection_id}
    end
  end

  @doc """
  Ends the room by the host's own decision, in the lobby or after it started.

  The room becomes `cancelled` — told apart from `expired` so the people in it
  can be given the real reason — everybody is released and the host is free to
  open another one, with a new code. A room that is already over answers
  `:invalid_transition`: there is no reopening.
  """
  @spec cancel_game_session(Scope.t(), GameSession.t(), keyword()) ::
          {:ok, GameSession.t()}
          | {:error, :unauthorized}
          | {:error, :invalid_transition}
          | {:error, :access_lost}
  # Every room decision by a host reads the room back through the scope, so
  # somebody who does not host it is refused instead of acting on it, and a
  # stale struct cannot smuggle a transition past the check either. `opts` may
  # carry `:connection_id`, the lease of the tab issuing the command, which is
  # compared inside the transition's own transaction.
  def cancel_game_session(%Scope{} = scope, %GameSession{} = session, opts \\ []) do
    case Room.fetch_hosted(scope, session) do
      {:ok, session} ->
        close_and_announce(session, :cancelled, :game_cancelled,
          connection_id: opts[:connection_id]
        )

      {:error, :unauthorized} = error ->
        error
    end
  end

  @doc """
  Ends the room because the host stayed away past the deadline.

  It takes no scope on purpose: this is the system acting, not a person, and
  the sweeper that calls it arrives in F2-06. Like cancelling, it only applies
  to a live room — a room already over answers `:invalid_transition`, which is
  what makes a host cancelling at the very second the deadline runs out a
  harmless race instead of a double close.
  """
  @spec expire_game_session(GameSession.t()) ::
          {:ok, GameSession.t()} | {:error, :invalid_transition} | {:error, :not_expired}
  def expire_game_session(%GameSession{expires_at: nil}), do: {:error, :not_expired}

  def expire_game_session(%GameSession{expires_at: %DateTime{} = deadline} = session) do
    close_and_announce(session, :expired, :game_expired, expires_at: deadline)
  end

  @doc """
  Records that the host lost the room and starts the countdown to expiration.

  Losing the connection does not end the room: `host_disconnected_at` and
  `expires_at = at + #{@host_absence_timeout}s` are written and the room stays
  exactly as it was. The deadline lives in the database rather than in a timer
  (AD-23), so restarting the application neither forgets it nor grants five
  fresh minutes.

  Idempotent: reporting the drop again while a deadline is already running does
  not push it forward. A room that is already over is left untouched.
  """
  @spec mark_host_disconnected(GameSession.t(), DateTime.t()) :: {:ok, GameSession.t()}
  def mark_host_disconnected(session, at \\ DateTime.utc_now())

  def mark_host_disconnected(%GameSession{id: id} = session, %DateTime{} = at) do
    at = DateTime.truncate(at, :second)
    expires_at = DateTime.add(at, @host_absence_timeout, :second)

    query =
      from s in GameSession,
        where: s.id == ^id,
        where: is_nil(s.host_disconnected_at),
        where: s.status in ^GameSession.active_statuses(),
        select: s

    case Repo.update_all(query,
           set: [host_disconnected_at: at, expires_at: expires_at, updated_at: at]
         ) do
      {1, [updated]} -> {:ok, updated}
      {0, _unchanged} -> {:ok, Room.reload(session)}
    end
  end

  @doc """
  Records the host coming back and drops the pending deadline.

  Both columns are cleared, so a later absence is worth **five full minutes**
  again instead of what was left of the previous one. That is the literal
  reading of "continuous absence" and a product decision, not an oversight.
  """
  @spec mark_host_connected(GameSession.t()) :: {:ok, GameSession.t()}
  def mark_host_connected(%GameSession{id: id} = session) do
    query =
      from s in GameSession,
        where: s.id == ^id,
        where: not is_nil(s.host_disconnected_at) or not is_nil(s.expires_at),
        select: s

    case Repo.update_all(query,
           set: [host_disconnected_at: nil, expires_at: nil, updated_at: Room.now()]
         ) do
      {1, [updated]} -> {:ok, updated}
      {0, _unchanged} -> {:ok, Room.reload(session)}
    end
  end

  @doc """
  The live room with this id, or `nil`.

  What the host monitor reads before deciding whether the connection holding
  the room is the one still present; a room that is over has no absence left to
  record.
  """
  @spec get_live_game_session(integer()) :: GameSession.t() | nil
  def get_live_game_session(session_id) when is_integer(session_id) do
    fetch_live_session(session_id)
  end

  @doc """
  Live rooms that have had a host connection at some point.

  What the host monitor reconciles presence against. A room opened through the
  API and never claimed from a socket is deliberately left out: it has no
  presence to compare with, and reading an empty presence as an absence would
  expire a room whose host is driving it over HTTP. What liveness means for
  those is a contract still to be defined.
  """
  @spec list_sessions_with_host_claim() :: [GameSession.t()]
  def list_sessions_with_host_claim do
    GameSession
    |> Room.live()
    |> where([s], not is_nil(s.host_connection_id))
    |> Repo.all()
  end

  @doc """
  Live rooms whose host absence deadline has already run out.

  This is what the sweeper of F2-06 reads. Only `waiting` and `in_progress`
  rooms come back, so a room that is over is never closed twice, and rooms with
  the host present have no deadline to compare in the first place. The instant
  is truncated to the second the column is stored in, so a deadline is never
  missed by microseconds; a deadline that ran out while the application was
  down is picked up by the first sweep after it returns, with no extra time.
  """
  @spec list_expired_sessions(DateTime.t()) :: [GameSession.t()]
  def list_expired_sessions(now \\ DateTime.utc_now()) do
    threshold = DateTime.truncate(now, :second)

    GameSession
    |> where([s], not is_nil(s.expires_at) and s.expires_at <= ^threshold)
    |> Room.live()
    |> order_by([s], asc: s.expires_at, asc: s.id)
    |> Repo.all()
  end

  @doc """
  How many seconds are left before the room expires.

  Answers `nil` when no deadline is running — the host is present — and `0`
  once the deadline is past, so the caller never has to reason about negative
  time.

  The lobby shows the instant itself rather than a countdown, so nothing in the
  application calls this; it is the seam the tests of the host dropping and
  coming back use to observe the deadline that was written.
  """
  @spec seconds_until_expiration(GameSession.t(), DateTime.t()) :: non_neg_integer() | nil
  def seconds_until_expiration(session, now \\ DateTime.utc_now())

  def seconds_until_expiration(%GameSession{expires_at: nil}, %DateTime{}), do: nil

  def seconds_until_expiration(%GameSession{expires_at: expires_at}, %DateTime{} = now) do
    max(DateTime.diff(expires_at, now, :second), 0)
  end

  @doc "How long a room survives the host being away, in seconds."
  @spec host_absence_timeout() :: pos_integer()
  def host_absence_timeout, do: @host_absence_timeout

  @doc """
  Tells whether the `connection_id` presented is still the live access of the
  participation.

  A participation nobody claimed yet has no live access at all, so every value
  gets `false`, `nil` included.

  Like `host_connection_current?/2`, nothing in the application asks this — the
  screens learn that they lost the room from `{:access_transferred, …}` instead.
  Both are the seam the tests of claiming and of taking over use to observe
  which connection the row actually holds.
  """
  @spec connection_current?(Participant.t(), Ecto.UUID.t()) :: boolean()
  def connection_current?(%Participant{connection_id: current}, connection_id) do
    same_connection?(current, connection_id)
  end

  @doc "Tells whether the `connection_id` presented is still the live access of the host."
  @spec host_connection_current?(GameSession.t(), Ecto.UUID.t()) :: boolean()
  def host_connection_current?(%GameSession{host_connection_id: current}, connection_id) do
    same_connection?(current, connection_id)
  end

  ## Events
  #
  # The topic and the way in are `LiveQuiz.Games.Topic`'s, so that every part of
  # this context — and the submodules split out of it — can publish without
  # reaching back through the context. They are delegated here because a topic
  # is something callers ask the context for.

  defdelegate topic(session_id), to: Topic
  defdelegate session_id_from_topic(topic), to: Topic
  defdelegate subscribe(session_id), to: Topic

  @doc """
  Records that the host has been away long enough to start the countdown, and
  announces it.

  Called by `LiveQuiz.Games.HostMonitor` once the grace period is over, never
  by a LiveView. A room that is already counting down, or already closed, is
  left exactly as it is and nothing is announced — which is what makes the
  monitor free to ask again.
  """
  @spec record_host_absence(integer(), DateTime.t()) :: {:ok, GameSession.t()} | :ignored
  def record_host_absence(session_id, at \\ DateTime.utc_now()) do
    with %GameSession{host_disconnected_at: nil} = session <- fetch_live_session(session_id),
         {:ok, %GameSession{expires_at: expires_at} = session} when not is_nil(expires_at) <-
           mark_host_disconnected(session, at) do
      Topic.broadcast(session_id, {:host_disconnected, expires_at})
      {:ok, session}
    else
      _already_counting_or_closed -> :ignored
    end
  end

  @doc """
  Records the host coming back, drops the pending deadline and announces it.

  Announces only when there was a deadline to drop, so the host merely opening
  the lobby says nothing to anybody. A deadline written before a restart is
  dropped here too: the monitor has no memory of it, the database does.
  """
  @spec record_host_return(integer()) :: {:ok, GameSession.t()} | :ignored
  def record_host_return(session_id) do
    case fetch_live_session(session_id) do
      %GameSession{host_disconnected_at: nil, expires_at: nil} ->
        :ignored

      %GameSession{} = session ->
        {:ok, session} = mark_host_connected(session)
        Topic.broadcast(session_id, {:host_connected, nil})
        {:ok, session}

      nil ->
        :ignored
    end
  end

  # The single place an event leaves this module, always after the transaction
  # that produced it (AD-31).
  defp fetch_live_session(session_id) do
    GameSession
    |> where([s], s.id == ^session_id)
    |> Room.live()
    |> Repo.one()
  end

  defp ensure_not_hosting(%Scope{} = scope) do
    if hosting?(scope), do: {:error, :host_already_in_session}, else: :ok
  end

  defp ensure_not_participating(%Scope{} = scope) do
    if participating?(scope), do: {:error, :already_participating}, else: :ok
  end

  defp hosting?(%Scope{} = scope), do: Room.hosting?(scope.user.id)

  defp participating?(%Scope{} = scope) do
    Participant
    |> where([p], p.user_id == ^scope.user.id and is_nil(p.released_at))
    |> Repo.exists?()
  end

  defp insert_with_join_code(_scope, _quiz, _attrs, 0), do: {:error, :code_generation_failed}

  defp insert_with_join_code(%Scope{} = scope, %Quiz{} = quiz, attrs, attempts_left) do
    %GameSession{host_id: scope.user.id, quiz_id: quiz.id}
    |> GameSession.create_changeset(create_attrs(quiz, attrs))
    # A rejected insert would poison the surrounding transaction and take the
    # retry down with it, so each attempt gets its own savepoint to roll back to.
    |> Repo.insert(mode: :savepoint)
    |> case do
      {:ok, %GameSession{} = session} ->
        {:ok, session}

      {:error, %Changeset{} = changeset} ->
        handle_insert_error(scope, quiz, attrs, changeset, attempts_left)
    end
  end

  # The title and the code are the room's own business and never come from the
  # caller; the duration is the only thing the host chooses, so it is the only
  # key read out of `attrs`. String and atom keys are both accepted because the
  # value reaches here either from a form or from a controller.
  defp create_attrs(%Quiz{} = quiz, attrs) do
    attrs
    |> Map.new(fn {key, value} -> {to_string(key), blank_to_nil(value)} end)
    |> Map.take(["question_duration_seconds"])
    |> Map.merge(%{"quiz_title" => quiz.title, "join_code" => generate_join_code()})
  end

  # A duration that arrives empty is not the same thing as a duration that was
  # never asked for: a caller that says nothing accepts the default of the
  # column, while a form submitted with nothing chosen has to be refused. Ecto
  # would read an empty string back as the column default, so the emptiness is
  # made explicit here, before the changeset sees it.
  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp handle_insert_error(scope, quiz, attrs, changeset, attempts_left) do
    cond do
      Room.unique_violation?(changeset, :join_code) ->
        # Astronomically unlikely with 32⁶ codes, so a collision is worth a
        # warning: it is either remarkable luck or a broken generator.
        Logger.warning(
          "join code for host #{scope.user.id} collided with a live room, " <>
            "#{attempts_left - 1} attempt(s) left"
        )

        insert_with_join_code(scope, quiz, attrs, attempts_left - 1)

      # The advisory lock already serializes the same person, so this only
      # fires if the lock is bypassed; answering with the same reason as the
      # explicit check keeps the contract stable either way.
      Room.unique_violation?(changeset, :host_id) ->
        {:error, :host_already_in_session}

      true ->
        {:error, changeset}
    end
  end

  defp generate_join_code do
    case Application.get_env(:live_quiz, :join_code_generator) do
      nil -> JoinCode.generate()
      generator when is_function(generator, 0) -> generator.()
    end
  end

  # Both ways of closing a room share the transition and differ only in the
  # event they announce, which is what tells a lobby whether to say "cancelled"
  # or "expired". The broadcast is outside the transaction on purpose (AD-31).
  defp close_and_announce(%GameSession{} = session, status, event, guards) do
    case close_session(session, status, guards) do
      {:ok, session} ->
        QuestionTimer.stop(session.id)
        Topic.broadcast(session.id, {event, session})
        {:ok, session}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Closing is terminal and guarded the same way, which is what makes the host
  # cancelling at the very second the deadline runs out end with exactly one
  # winner and a single status. Releasing everybody rides in the same
  # transaction, so a closed room never leaves people tied to it.
  defp close_session(%GameSession{id: id}, status, guards) do
    true = status in GameSession.closed_statuses()
    at = Room.now()

    query =
      from s in GameSession,
        where: s.id == ^id and s.status in ^GameSession.active_statuses(),
        select: s

    query = apply_close_guards(query, guards, at)

    Repo.transaction(fn ->
      # Both room locks, in the order `LiveQuiz.Games.Locks` fixes. The seats
      # one is what makes a join already under way either finish first — and be
      # released along with everybody — or wait here and find the room over. It
      # used to be absent, so a participation could be inserted after the
      # release ran and leave somebody tied to a room that had ended (R16).
      Locks.room(id)

      with :ok <- ensure_in_control(id, guards[:connection_id]),
           {1, [session]} <-
             Repo.update_all(query,
               set: [status: status, finished_at: at, expires_at: nil, updated_at: at]
             ) do
        Room.release_participants(id, at)
        session
      else
        {0, _unchanged} -> Repo.rollback(close_refusal(id, guards))
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp ensure_in_control(_id, nil), do: :ok

  defp ensure_in_control(id, connection_id) do
    case Repo.get(GameSession, id) do
      nil -> {:error, :invalid_transition}
      %GameSession{} = session -> Room.ensure_in_control(session, connection_id)
    end
  end

  # Expiring carries the deadline the sweeper selected the room on, and the
  # `UPDATE` only fires while the database still holds that very deadline and it
  # has run out. A host who came back cleared it, and a host who dropped again
  # wrote a new one: neither matches, so a sweep that read the room a moment too
  # early closes nothing (R17).
  defp apply_close_guards(query, guards, at) do
    case guards[:expires_at] do
      nil ->
        query

      deadline ->
        query
        |> where([s], s.expires_at == ^deadline)
        |> where([s], s.expires_at <= ^at)
    end
  end

  # A refusal has to say which of the two conditions failed, because the sweeper
  # skips a room whose deadline moved and would otherwise treat it as a broken
  # transition worth reporting.
  defp close_refusal(id, guards) do
    case guards[:expires_at] do
      nil ->
        :invalid_transition

      _deadline ->
        case Repo.get(GameSession, id) do
          %GameSession{status: status} when status in [:waiting, :in_progress] -> :not_expired
          _over_or_gone -> :invalid_transition
        end
    end
  end

  # One statement for the whole room. Only `released_at` is stamped: whoever was
  # there stays recorded as present at the end, which is what phase 4 reads back
  # as history, and clearing the one-room-per-account index violates nothing.
  defp same_connection?(current, presented) do
    is_binary(current) and is_binary(presented) and current == presented
  end
end
