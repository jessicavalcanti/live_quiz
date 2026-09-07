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

  Entering a room is where several people decide the same things at the same
  instant, so nothing here is settled optimistically: the nickname is arbitrated
  by a unique index, the 25 seats are counted under an advisory lock on the room
  and "one room per person" is serialized by an advisory lock on the account.
  Locks are always taken in the same order — identity first, room second — which
  is what keeps `join_game_session/4` from deadlocking against
  `rejoin_game_session/2` and the operations F2-05 adds on the same rows.

  Whoever joins gets a `LiveQuiz.Games.ParticipantToken`, returned in clear only
  by `join_game_session/4` and stored only as a digest.

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
  alias LiveQuiz.Accounts.User
  alias LiveQuiz.Games.Access
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.History
  alias LiveQuiz.Games.JoinCode
  alias LiveQuiz.Games.Locks
  alias LiveQuiz.Games.Match
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Games.ParticipantToken
  alias LiveQuiz.Games.Presence
  alias LiveQuiz.Games.QuestionTimer
  alias LiveQuiz.Games.QuizLock
  alias LiveQuiz.Games.Room
  alias LiveQuiz.Games.Scoring
  alias LiveQuiz.Games.Topic
  alias LiveQuiz.Quizzes
  alias LiveQuiz.Quizzes.Quiz
  alias LiveQuiz.Repo

  @max_participants 25
  # How long a room outlives the host being away, in seconds. It is a domain
  # constant rather than a configuration knob: the lobby countdown, the
  # persisted `expires_at` and the sweeper of F2-06 all have to agree on it.
  @host_absence_timeout 300
  # `known_tokens` comes from the client, so the list is bounded before it turns
  # into a query and malformed values are dropped without an error.
  @max_known_tokens 20

  @type join_error ::
          :session_not_found
          | :session_not_joinable
          | :session_full
          | :nickname_taken
          | :already_in_another_session
          | Changeset.t()

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
  defdelegate close_question(scope, session), to: Match
  defdelegate close_question_by_timeout(session_id), to: Match
  defdelegate list_sessions_with_open_question(), to: Match
  defdelegate get_session_for_timeout(session_id), to: Match
  defdelegate answer_question(participant, answer_option_id, connected_count), to: Match
  defdelegate current_answers_count(session), to: Match
  defdelegate finish_game_session(scope, session), to: Match
  defdelegate game_state(session, viewer), to: Match
  defdelegate question_results(session, position, viewer), to: Match
  defdelegate game_summary(session, viewer), to: Match

  def create_game_session(scope, quiz_id, attrs \\ %{})

  def create_game_session(%Scope{} = scope, quiz_id, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      Locks.identity(scope.user.id)
      quiz = Quizzes.get_quiz!(scope, quiz_id)
      # The same row lock `LiveQuiz.Quizzes` takes before every write (F2-07).
      # Taking it here is what turns the block into a real guarantee: an edit
      # already under way finishes before the room exists, and one that starts
      # afterwards finds the room and is refused.
      QuizLock.lock_quiz!(quiz.id)

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
      with {:ok, session} <- fetch_joinable_session(code),
           {:ok, :new} <- resolve_identity(scope, session, known),
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
    with {:ok, %GameSession{} = session} <- get_game_session_by_code(code) do
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
         {:ok, %GameSession{id: id}} <- get_game_session_by_code(code),
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
  def leave_game_session(%Participant{} = participant) do
    if Participant.in_lobby?(participant) do
      at = Room.now()

      changeset = Participant.connection_changeset(participant, %{left_at: at, released_at: at})

      # Stamping `released_at` only takes the row out of the one-room-per-account
      # index, so there is no constraint left for this update to violate.
      participant = Repo.update!(changeset)

      Topic.broadcast(participant.game_session_id, {:participant_left, participant})

      {:ok, participant}
    else
      {:ok, participant}
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
      with {:ok, participant} <- fetch_participant_for_rejoin(token),
           :ok <- ensure_session_live(participant.game_session),
           :ok <- ensure_free_to_rejoin(participant, known),
           {:ok, participant} <- restore_participation(participant) do
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
  @spec cancel_game_session(Scope.t(), GameSession.t()) ::
          {:ok, GameSession.t()} | {:error, :unauthorized} | {:error, :invalid_transition}
  # Every room decision by a host reads the room back through the scope, so
  # somebody who does not host it is refused instead of acting on it, and a
  # stale struct cannot smuggle a transition past the check either.
  def cancel_game_session(%Scope{} = scope, %GameSession{} = session) do
    case Room.fetch_hosted(scope, session) do
      {:ok, session} -> close_and_announce(session, :cancelled, :game_cancelled)
      {:error, :unauthorized} = error -> error
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
          {:ok, GameSession.t()} | {:error, :invalid_transition}
  def expire_game_session(%GameSession{} = session) do
    close_and_announce(session, :expired, :game_expired)
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

  defp hosting?(%Scope{} = scope), do: hosting_user?(scope.user.id)

  defp hosting_user?(user_id) do
    GameSession
    |> where([s], s.host_id == ^user_id)
    |> Room.live()
    |> Repo.exists?()
  end

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
      taken?(changeset, :join_code) ->
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
      taken?(changeset, :host_id) ->
        {:error, :host_already_in_session}

      true ->
        {:error, changeset}
    end
  end

  defp taken?(%Changeset{errors: errors}, field) do
    Enum.any?(errors, fn
      {^field, {_message, opts}} -> opts[:constraint] == :unique
      _other_field -> false
    end)
  end

  defp generate_join_code do
    case Application.get_env(:live_quiz, :join_code_generator) do
      nil -> JoinCode.generate()
      generator when is_function(generator, 0) -> generator.()
    end
  end

  defp fetch_joinable_session(code) do
    case get_game_session_by_code(code) do
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

    if hosting?(scope) do
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

  defp ensure_seat_available(%GameSession{} = session) do
    Locks.seats(session.id)

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
      taken?(changeset, :nickname) -> :nickname_taken
      taken?(changeset, :user_id) -> :already_in_another_session
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

  defp ensure_session_live(%GameSession{} = session) do
    if GameSession.active?(session), do: :ok, else: {:error, :session_ended}
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

    if hosting_user?(user_id) or participating_elsewhere?(participant) do
      {:error, :already_in_another_session}
    else
      :ok
    end
  end

  defp restore_participation(%Participant{left_at: nil, released_at: nil} = participant) do
    {:ok, participant}
  end

  defp restore_participation(%Participant{} = participant) do
    participant
    |> Participant.connection_changeset(%{left_at: nil, released_at: nil})
    # Clearing `released_at` puts the row back into the one-room-per-account
    # index, and the check above is only the first line of defence, so the
    # update takes its own savepoint and the violation is read back as the same
    # refusal instead of leaking a changeset.
    |> Repo.update(mode: :savepoint)
    |> case do
      {:ok, %Participant{} = participant} -> {:ok, participant}
      {:error, %Changeset{}} -> {:error, :already_in_another_session}
    end
  end

  defp participating_elsewhere?(%Participant{id: id, user_id: user_id}) do
    Participant
    |> where([p], p.user_id == ^user_id and is_nil(p.released_at) and p.id != ^id)
    |> Repo.exists?()
  end

  # Both ways of closing a room share the transition and differ only in the
  # event they announce, which is what tells a lobby whether to say "cancelled"
  # or "expired". The broadcast is outside the transaction on purpose (AD-31).
  defp close_and_announce(%GameSession{} = session, status, event) do
    case close_session(session, status) do
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
  defp close_session(%GameSession{id: id}, status) do
    true = status in GameSession.closed_statuses()
    at = Room.now()

    query =
      from s in GameSession,
        where: s.id == ^id and s.status in ^GameSession.active_statuses(),
        select: s

    Repo.transaction(fn ->
      case Repo.update_all(query,
             set: [status: status, finished_at: at, expires_at: nil, updated_at: at]
           ) do
        {1, [session]} ->
          Room.release_participants(id, at)
          session

        {0, _unchanged} ->
          Repo.rollback(:invalid_transition)
      end
    end)
  end

  # One statement for the whole room. Only `released_at` is stamped: whoever was
  # there stays recorded as present at the end, which is what phase 4 reads back
  # as history, and clearing the one-room-per-account index violates nothing.
  defp same_connection?(current, presented) do
    is_binary(current) and is_binary(presented) and current == presented
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
