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
  couple of aggregates and materializing a result belongs to phase 4 — and it
  refuses a question that has not ended, so the key cannot leak through a screen
  or an endpoint that asks too early. `game_summary/2` closes the match with the
  same reading: how far it got and how much was answered. Neither of them scores
  anything; there is no point, bonus or position in phase 3.

  Everything a room does is announced on `topic/1` after the transaction that
  did it has committed (AD-31): a subscriber woken by `{:participant_joined, p}`
  that reads the database has to find the participation there. Events are
  tuples carrying structs, so a subscriber pattern matches them and the
  compiler has something to complain about when one of them changes. Nothing
  outside this module publishes them.

  ## Events of a running match

  All of them travel on the room's single topic, the same one the lobby of
  phase 2 uses (AD-45); the execution adds no topic of its own.

  | Event | Published by |
  |---|---|
  | `{:game_started, %GameSession{}}` | `start_game_session/3` |
  | `{:question_advanced, %GameSession{}}` | `advance_question/3` |
  | `{:answer_submitted, session_id, count}` | `answer_question/3` |
  | `{:question_closed, %GameSession{}}` | `close_question/2`, `close_question_by_timeout/1` and `answer_question/3` |
  | `{:game_finished, %GameSession{}}` | `finish_game_session/2` |

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
  alias LiveQuiz.Games.Answer
  alias LiveQuiz.Games.GameResult
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.GameSessionAnswerOption
  alias LiveQuiz.Games.GameSessionQuestion
  alias LiveQuiz.Games.JoinCode
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Games.ParticipantToken
  alias LiveQuiz.Games.Presence
  alias LiveQuiz.Games.QuestionTimer
  alias LiveQuiz.Games.QuizLock
  alias LiveQuiz.Quizzes
  alias LiveQuiz.Quizzes.Question
  alias LiveQuiz.Quizzes.Quiz
  alias LiveQuiz.Repo

  # Advisory locks are a single namespace shared by the whole application, so
  # the first key is a class: `1` means "the identity of one person". Stories
  # that also serialize per account (F2-03, F2-05) must reuse it, and anything
  # locking on a different subject must pick another class.
  @identity_lock_class 1
  # Class `2` means "the seats of one room". Counting under it is what makes
  # `count(*) < 25` a decision instead of a guess, and it never blocks a join
  # into a different room.
  @seats_lock_class 2
  # Class `3` means "the progress of one match". Only the commands that move a
  # match from one question to the next take it, and they take nothing else, so
  # they serialize against each other without ever waiting on a join or on
  # another room.
  @match_lock_class 3

  @topic_prefix "game_session:"

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
  def create_game_session(scope, quiz_id, attrs \\ %{})

  def create_game_session(%Scope{} = scope, quiz_id, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      lock_identity(scope.user.id)
      quiz = Quizzes.get_quiz!(scope, quiz_id)
      # The same row lock `LiveQuiz.Quizzes` takes before every write (F2-07).
      # Taking it here is what turns the block into a real guarantee: an edit
      # already under way finishes before the room exists, and one that starts
      # afterwards finds the room and is refused.
      QuizLock.lock_quiz!(quiz.id)

      with :ok <- ensure_playable(quiz),
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
  Fetches a room hosted by the scope user.

  Raises `Ecto.NoResultsError` when the room does not exist or is hosted by
  somebody else.
  """
  @spec get_game_session!(Scope.t(), integer() | String.t()) :: GameSession.t()
  def get_game_session!(%Scope{} = scope, id) do
    scope
    |> hosted_sessions()
    |> where([s], s.id == ^id)
    |> Repo.one!()
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
      |> live()
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
    |> hosted_sessions()
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
    |> hosted_sessions()
    |> live()
    |> Repo.one()
  end

  @doc """
  Tells whether the scope user is tied to any room, hosting or taking part in it.

  Someone who left a room but was not released yet still counts: the seat is
  theirs until the room lets it go (AD-27).
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
        broadcast(participant.game_session_id, {:participant_joined, participant})
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
      at = now()

      changeset = Participant.connection_changeset(participant, %{left_at: at, released_at: at})

      # Stamping `released_at` only takes the row out of the one-room-per-account
      # index, so there is no constraint left for this update to violate.
      participant = Repo.update!(changeset)

      broadcast(participant.game_session_id, {:participant_left, participant})

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
        broadcast(participant.game_session_id, {:participant_rejoined, participant})
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

    broadcast(participant.game_session_id, {:access_transferred, participant.id, connection_id})

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
    case fetch_hosted_session(scope, session) do
      {:error, :unauthorized} = error ->
        error

      {:ok, session} ->
        connection_id = Ecto.UUID.generate()

        session =
          session
          |> GameSession.host_presence_changeset(%{host_connection_id: connection_id})
          |> Repo.update!()

        broadcast(session.id, {:host_access_transferred, connection_id})

        {:ok, session, connection_id}
    end
  end

  @doc """
  Puts the room live, freezing the quiz into it, which is the only way out of
  the lobby.

  Only the host may start it, only from `waiting`, and only with at least one
  participant **connected** — `connected_count` is informed by whoever watches
  the presence of the room, so the rule stays in the context while the counting
  stays out of it (AD-23). Somebody merely signed up, disconnected or gone does
  not count.

  Starting copies every question of the quiz, with its options and its answer
  key, into the match, and flips the status in the **same transaction** (AD-36):
  a room that is `in_progress` without a snapshot could neither be advanced nor
  played, so either the whole content is frozen or nothing happens at all. From
  that instant the match no longer reads the quiz — see
  `list_snapshot_questions/1` — and editing or deleting the quiz afterwards
  cannot rewrite what was played.

  The quiz is checked again here, and not only when the room was opened: the
  lobby may have lasted any amount of time. A quiz that lost its questions
  answers `:quiz_not_playable`, and one that is gone answers `:quiz_unavailable`.

  Idempotent for the host: asking again for a match that is already running
  gives that match back, with the snapshot it already has and without a second
  `{:game_started, session}`. That courtesy is the host's alone — anybody else
  is `:unauthorized`, and a room that is over never reopens.
  """
  @spec start_game_session(Scope.t(), GameSession.t(), non_neg_integer()) ::
          {:ok, GameSession.t()}
          | {:error, :unauthorized}
          | {:error, :invalid_transition}
          | {:error, :no_connected_participants}
          | {:error, :quiz_not_playable}
          | {:error, :quiz_unavailable}
  def start_game_session(%Scope{} = scope, %GameSession{} = session, connected_count)
      when is_integer(connected_count) and connected_count >= 0 do
    case fetch_hosted_session(scope, session) do
      {:ok, %GameSession{status: :in_progress} = running} -> {:ok, running}
      {:ok, %GameSession{} = current} -> start_and_announce(scope, current, connected_count)
      {:error, :unauthorized} = error -> error
    end
  end

  @doc """
  The frozen questions of a match, in order, with their options preloaded.

  This is the only content an ongoing match ever reads: it touches
  `game_session_questions` and `game_session_answer_options` and never the quiz
  tables (AD-36), so it answers just the same after the quiz has been deleted.
  """
  @spec list_snapshot_questions(GameSession.t()) :: [GameSessionQuestion.t()]
  def list_snapshot_questions(%GameSession{id: id}) do
    id
    |> snapshot_questions()
    |> order_by([q], asc: q.position)
    |> preload(:answer_options)
    |> Repo.all()
  end

  @doc """
  The frozen question at a position of a match, with its options preloaded.

  Positions run from 1 to `snapshot_question_count/1` with no gaps, whatever
  the quiz they were copied from looked like.
  """
  @spec get_snapshot_question(GameSession.t(), pos_integer()) ::
          {:ok, GameSessionQuestion.t()} | {:error, :not_found}
  def get_snapshot_question(%GameSession{id: id}, position) when is_integer(position) do
    id
    |> snapshot_questions()
    |> where([q], q.position == ^position)
    |> preload(:answer_options)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      %GameSessionQuestion{} = question -> {:ok, question}
    end
  end

  @doc """
  How many questions were frozen into the match.

  Zero for a room still in the lobby: the snapshot only exists from the start
  onwards.
  """
  @spec snapshot_question_count(GameSession.t()) :: non_neg_integer()
  def snapshot_question_count(%GameSession{id: id}) do
    id |> snapshot_questions() |> Repo.aggregate(:count, :id)
  end

  @doc """
  How many questions the room announces it is going to play.

  Before the start there is no snapshot yet, so the number can only come from
  the quiz the room was opened from — which cannot change underneath it, since
  a live room locks its quiz against edits (AD-32). From the start onwards the
  snapshot is the only source read, as the match owes nothing to the quiz any
  more (AD-36). A room whose quiz was deleted before it ever started announces
  zero, which is the truth: there is nothing left to play.
  """
  @spec question_count(GameSession.t()) :: non_neg_integer()
  def question_count(%GameSession{} = session) do
    case snapshot_question_count(session) do
      0 -> quiz_question_count(session)
      count -> count
    end
  end

  defp quiz_question_count(%GameSession{quiz_id: nil}), do: 0

  defp quiz_question_count(%GameSession{quiz_id: quiz_id}) do
    Question
    |> where([q], q.quiz_id == ^quiz_id)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Advances the match to the next question and opens it for answers.

  Advancing is the only thing that moves a match forward, and it only ever
  produces `position + 1` (AD-44): there is no destination to ask for, so there
  is no way to go back, to skip or to reopen. Opening is not a command of its
  own — a question just advanced to is already taking answers, which is what
  the refinement decided so the host has one button instead of two.

  `expected_position` is the position the caller believes is current, and `nil`
  only before the very first question. It is compared inside the transaction
  and answers `:stale` when it does not match: that is what stops two clicks —
  or one on the web and another on the API — from skipping a question between
  them.

  A question still open is closed in the same transaction before the next one
  opens, so a match never leaves a question behind with no ending.

  The deadline is absolute and computed by the server (AD-39):
  `current_question_started_at` is now and `current_question_ends_at` is that
  instant plus the duration the room was opened with.

  Only the host commands a match, and only while it is running: anybody else is
  `:unauthorized`, and a room in the lobby or already over is `:invalid_status`.
  """
  @spec advance_question(Scope.t(), GameSession.t(), pos_integer() | nil) ::
          {:ok, GameSession.t()}
          | {:error, :unauthorized | :invalid_status | :no_more_questions | :stale}
  def advance_question(%Scope{} = scope, %GameSession{} = session, expected_position)
      when is_nil(expected_position) or
             (is_integer(expected_position) and expected_position > 0) do
    with {:ok, hosted} <- fetch_hosted_session(scope, session),
         {:ok, advanced} <- open_next_question(hosted, expected_position) do
      QuestionTimer.ensure_started(advanced)
      broadcast(advanced.id, {:question_advanced, advanced})
      {:ok, advanced}
    end
  end

  @doc """
  Closes the question that is open, by the host's own decision.

  Closing is what reveals the answer key; the question stays on screen, closed,
  until the host advances. It never ends the match — even the last question
  waits for `finish_game_session/2`, because finishing is a decision of the
  host and not a consequence of running out of questions.

  Idempotent: asking again for a question already closed gives the match back
  with the instant it was closed at untouched and without a second
  `{:question_closed, session}`, so a repeated click does not replay the
  reveal. A match that has not advanced to any question has nothing to close
  and answers `:no_open_question`.
  """
  @spec close_question(Scope.t(), GameSession.t()) ::
          {:ok, GameSession.t()} | {:error, :unauthorized | :invalid_status | :no_open_question}
  def close_question(%Scope{} = scope, %GameSession{} = session) do
    with {:ok, hosted} <- fetch_hosted_session(scope, session),
         {:ok, outcome} <- close_current_question(hosted) do
      QuestionTimer.stop(hosted.id)

      case outcome do
        {:closed, closed} ->
          score_and_publish_ranking(closed)
          broadcast(closed.id, {:question_closed, closed})
          {:ok, closed}

        {:already_closed, closed} ->
          {:ok, closed}
      end
    end
  end

  @doc """
  Closes the question that is open because its deadline ran out.

  It takes no scope on purpose: the caller is the timer of F3-05, that is, the
  system, exactly like `expire_game_session/1`. Nobody has to be host to let
  time pass, and no screen has to be connected for it to run out — a match whose
  host dropped keeps closing its questions on time, it simply does not advance
  on its own.

  The deadline is checked here, inside the transaction and against the database
  (AD-39): a question with time still on the clock answers `:not_due` and stays
  open, which is what makes a timer that fired early harmless. A question
  already closed — by the host, by everybody having answered or by another
  timer — gives the match back with its closing instant untouched and without a
  second `{:question_closed, session}`, so the three ways a question can end
  converge on a single reveal.

  The result is indistinguishable from `close_question/2`: same columns, same
  event. Only the origin differs.
  """
  @spec close_question_by_timeout(integer()) ::
          {:ok, GameSession.t()}
          | {:error, :not_found | :invalid_status | :no_open_question | :not_due}
  def close_question_by_timeout(session_id) when is_integer(session_id) do
    case close_due_question(session_id) do
      {:ok, {:closed, closed}} ->
        score_and_publish_ranking(closed)
        broadcast(closed.id, {:question_closed, closed})
        {:ok, closed}

      {:ok, {:already_closed, closed}} ->
        {:ok, closed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Calculates an answer's score from the frozen answer key and server timestamps.

  Correct answers are worth up to 1000 points, proportional to the time left
  when they arrived. Missing and incorrect answers are worth zero.
  """
  @spec calculate_answer_score(Answer.t() | nil, GameSessionQuestion.t(), GameSession.t()) ::
          non_neg_integer()
  def calculate_answer_score(nil, %GameSessionQuestion{}, %GameSession{}), do: 0

  def calculate_answer_score(
        %Answer{} = answer,
        %GameSessionQuestion{answer_options: options},
        %GameSession{question_duration_seconds: duration} = session
      )
      when is_list(options) and is_integer(duration) and duration > 0 do
    option = Enum.find(options, &(&1.id == answer.game_session_answer_option_id))

    if option && option.is_correct do
      elapsed_ms = elapsed_time_ms(answer.answered_at, session.current_question_started_at)
      remaining_ms = max(duration * 1_000 - elapsed_ms, 0)
      min(div(1_000 * remaining_ms, duration * 1_000), 1_000)
    else
      0
    end
  end

  defp elapsed_time_ms(%DateTime{} = answered_at, %DateTime{} = started_at) do
    max(DateTime.diff(answered_at, started_at, :millisecond), 0)
  end

  defp score_question(session_id, question_position) do
    Repo.transaction(fn ->
      lock_match(session_id)

      session = lock_session(session_id)

      case session do
        nil -> Repo.rollback(:not_found)
        %GameSession{} = current -> score_locked_question(current, session_id, question_position)
      end
    end)
  end

  defp score_locked_question(session, session_id, question_position) do
    with {:ok, running} <- ensure_running(session),
         :ok <- ensure_question_settled(running, question_position),
         {:ok, question} <- lock_snapshot_question(session_id, question_position) do
      answers = answers_for_question(question.id)
      participants = participants_for_scoring(session_id)

      case question.scored_at do
        %DateTime{} ->
          %{session: running, ranking_data: ranking_data(participants), scored?: false}

        nil ->
          scores = score_participants(participants, answers, question, running)
          mark_question_scored(question)

          %{session: running, ranking_data: scores, scored?: true}
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_snapshot_question(session_id, position) do
    GameSessionQuestion
    |> where([q], q.game_session_id == ^session_id and q.position == ^position)
    |> lock("FOR UPDATE")
    |> preload(:answer_options)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      question -> {:ok, question}
    end
  end

  defp answers_for_question(question_id) do
    Answer
    |> where([a], a.game_session_question_id == ^question_id)
    |> preload(:game_session_answer_option)
    |> Repo.all()
    |> Map.new(&{&1.participant_id, &1})
  end

  defp participants_for_scoring(session_id) do
    Participant
    |> where([p], p.game_session_id == ^session_id)
    |> order_by([p], asc: p.id)
    |> Repo.all()
  end

  defp score_participants(participants, answers, question, session) do
    participants
    |> Enum.map(fn participant ->
      answer = Map.get(answers, participant.id)
      score = calculate_answer_score(answer, question, session)
      answered? = not is_nil(answer)
      correct? = answered? and score > 0
      response_time = response_time_ms(answer, session.current_question_started_at)

      metrics = %{
        score: participant.score + score,
        correct_answers: participant.correct_answers + if(correct?, do: 1, else: 0),
        incorrect_answers:
          participant.incorrect_answers + if(answered? and not correct?, do: 1, else: 0),
        total_response_time_ms: participant.total_response_time_ms + response_time
      }

      participant
      |> Ecto.Changeset.change(metrics)
      |> Repo.update!()
      |> participant_ranking_data()
    end)
    |> Enum.sort_by(
      &{-&1.score, -&1.correct_answers, &1.total_response_time_ms, &1.participant_id}
    )
    |> Enum.with_index(1)
    |> Enum.map(fn {participant, position} -> Map.put(participant, :position, position) end)
  end

  defp response_time_ms(nil, _started_at), do: 0

  defp response_time_ms(%Answer{answered_at: answered_at}, %DateTime{} = started_at) do
    elapsed_time_ms(answered_at, started_at)
  end

  defp mark_question_scored(%GameSessionQuestion{id: id}) do
    {1, _} =
      Repo.update_all(
        from(q in GameSessionQuestion, where: q.id == ^id and is_nil(q.scored_at)),
        set: [scored_at: now_usec()]
      )

    :ok
  end

  defp ranking_data(participants) do
    participants
    |> Enum.map(&participant_ranking_data/1)
    |> Enum.sort_by(
      &{-&1.score, -&1.correct_answers, &1.total_response_time_ms, &1.participant_id}
    )
    |> Enum.with_index(1)
    |> Enum.map(fn {participant, position} -> Map.put(participant, :position, position) end)
  end

  defp ranking_participants(session_id) do
    Participant
    |> where([p], p.game_session_id == ^session_id)
    |> order_by([p],
      desc: p.score,
      desc: p.correct_answers,
      asc: p.total_response_time_ms,
      asc: p.id
    )
    |> Repo.all()
  end

  defp participant_ranking_data(participant) do
    %{
      participant_id: participant.id,
      nickname: participant.nickname,
      score: participant.score,
      correct_answers: participant.correct_answers,
      incorrect_answers: participant.incorrect_answers,
      total_response_time_ms: participant.total_response_time_ms
    }
  end

  defp participant_ranking_data(participant, position) do
    participant
    |> participant_ranking_data()
    |> Map.put(:position, position)
  end

  @doc """
  Consolidates every participant's last answer for a closed question.

  A persisted marker, protected by the match and question row locks, makes
  repeated and concurrent calls return the same ranking without duplicating
  participant metrics. The event is published only after commit.
  """
  @spec score_closed_question(GameSession.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, :question_open | :not_found | :invalid_status}
  def score_closed_question(%GameSession{id: session_id}, question_position)
      when is_integer(question_position) and question_position > 0 do
    case score_question(session_id, question_position) do
      {:ok, %{session: session, ranking_data: ranking_data, scored?: true}} ->
        broadcast(session.id, {:question_scored, session, ranking_data})
        publish_ranking(session.id, ranking_data)
        {:ok, ranking_data}

      {:ok, %{ranking_data: ranking_data, scored?: false}} ->
        {:ok, ranking_data}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp score_and_publish_ranking(%GameSession{
         id: session_id,
         current_question_position: position
       }) do
    case score_question(session_id, position) do
      {:ok, %{ranking_data: ranking_data, scored?: true}} ->
        publish_ranking(session_id, ranking_data)

      {:ok, %{scored?: false}} ->
        :ok

      {:error, reason} ->
        Logger.warning("could not score closed question: #{inspect(reason)}")
    end
  end

  @doc """
  Returns the current ranking of a match to its host or a participant.

  The query orders every participant by the competition rules, then assigns a
  sequential position in that same order. A participant remains visible after
  disconnecting because ranking is based on persisted metrics, not presence.
  """
  @spec current_ranking(GameSession.t(), Scope.t() | Participant.t()) ::
          {:ok, [map()]} | {:error, :unauthorized}
  def current_ranking(%GameSession{} = session, viewer) do
    current = reload_session(session)

    if allowed_to_watch?(current, viewer) do
      current.id
      |> ranking_participants()
      |> Enum.with_index(1)
      |> Enum.map(fn {participant, position} ->
        participant_ranking_data(participant, position)
      end)
      |> then(&{:ok, &1})
    else
      {:error, :unauthorized}
    end
  end

  @doc "Publishes the ranking after the transaction that calculated it commits."
  @spec publish_ranking(integer(), [map()]) :: :ok
  def publish_ranking(game_session_id, ranking)
      when is_integer(game_session_id) and is_list(ranking) do
    broadcast(game_session_id, {:ranking_updated, ranking})
  end

  @doc """
  Every running match sitting on a question that is still taking answers.

  This is what the boot recovery of F3-05 reads. Matches that are over never
  come back, whatever their columns say, so a cancelled room stopped mid
  question is left exactly as it was. The order is the deadline itself, so the
  most overdue question is the first one settled.
  """
  @spec list_sessions_with_open_question() :: [GameSession.t()]
  def list_sessions_with_open_question do
    GameSession
    |> where([s], s.status == :in_progress)
    |> where([s], not is_nil(s.current_question_position))
    |> where([s], is_nil(s.current_question_closed_at))
    |> order_by([s], asc: s.current_question_ends_at, asc: s.id)
    |> Repo.all()
  end

  @doc """
  The match a timer is keeping the deadline of, read without a scope.

  There is no owner to filter by: the caller is the system, like
  `close_question_by_timeout/1`. It exists so the timer can compare the position
  it was armed for with the one the match is actually on before closing
  anything — a message scheduled for question 1 and delivered after the host
  advanced must recognize itself as late and do nothing.
  """
  @spec get_session_for_timeout(integer()) :: {:ok, GameSession.t()} | {:error, :not_found}
  def get_session_for_timeout(session_id) when is_integer(session_id) do
    case Repo.get(GameSession, session_id) do
      nil -> {:error, :not_found}
      %GameSession{} = session -> {:ok, session}
    end
  end

  @doc """
  Records or replaces the answer of a participant to the question that is open.

  Changing one's mind is part of playing: while the question is open the answer
  may be sent again, and the last one is the one that counts. It is written by
  a single upsert on `(participant_id, game_session_question_id)` (AD-41), so
  two taps of the same person in the same instant end as one row instead of
  racing a `SELECT` against an `INSERT`, and the unique index never reaches the
  caller as an exception. The option and `answered_at` are both rewritten,
  because phase 4 measures the speed of the choice that stayed, not of the one
  that was abandoned.

  Whether the answer arrived in time is decided here, against
  `current_question_ends_at` as the database holds it (AD-39). A screen still
  showing the question open is not an argument: a millisecond past the deadline
  is `:time_is_up`.

  `connected_count` comes from whoever watches the presence of the room (AD-23)
  and is used for one thing only — deciding whether this answer was the last
  one missing. When the answers of the current question reach it, the question
  is closed inside this very transaction, under the same advisory lock the
  host's commands take (AD-42), so two final answers cannot both conclude "only
  I was missing" and close it twice. With nobody connected the rule never
  fires, and the question waits for the deadline or for the host.

  Being connected is deliberately *not* required in order to answer: somebody
  may tap at the exact instant the presence has yet to register them, and
  refusing that would punish the player for a detail of the infrastructure.
  What is required is an active participation — whoever left the room answers
  `:left_session` — a running match, an open question, and an option of that
  very question, checked against the database instead of trusted from the id
  that arrived.

  Every accepted answer announces `{:answer_submitted, session_id, count}`
  after the commit, and `{:question_closed, session}` as well when it was the
  one that closed the question. A refused answer writes nothing and announces
  nothing.

  > Swapping the option over and over writes without a limit. That was weighed
  > in the refinement and accepted; a rate limit, if it ever becomes necessary,
  > belongs right here, before the transaction opens.
  """
  @spec answer_question(Participant.t(), integer(), non_neg_integer()) ::
          {:ok, %{answer: Answer.t(), session: GameSession.t(), closed?: boolean()}}
          | {:error,
             :invalid_status
             | :no_open_question
             | :question_closed
             | :time_is_up
             | :option_not_found
             | :left_session}
  def answer_question(%Participant{} = participant, answer_option_id, connected_count)
      when is_integer(answer_option_id) and is_integer(connected_count) and
             connected_count >= 0 do
    case record_answer(participant, answer_option_id, connected_count) do
      {:ok, %{session: session, closed?: closed?, count: count} = recorded} ->
        broadcast(session.id, {:answer_submitted, session.id, count})

        if closed? do
          QuestionTimer.stop(session.id)
          score_and_publish_ranking(session)
          broadcast(session.id, {:question_closed, session})
        end

        {:ok, Map.take(recorded, [:answer, :session, :closed?])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The answer the participant currently holds on the question of the moment.

  It is the choice that stayed, never a history: swapping rewrites the row. The
  answer is given back while the question is open and after it closes, since
  the reveal shows people what they had picked.

  `nil` when the person has not answered, and also when the match has not
  advanced to any question yet.
  """
  @spec get_current_answer(GameSession.t(), Participant.t()) :: Answer.t() | nil
  def get_current_answer(%GameSession{} = session, %Participant{id: participant_id}) do
    case current_question_id(session) do
      nil ->
        nil

      question_id ->
        Repo.get_by(Answer,
          participant_id: participant_id,
          game_session_question_id: question_id
        )
    end
  end

  @doc """
  How many participations have already answered the question of the moment.

  Whoever did not answer leaves no row at all (AD-43), so this is a plain count
  and never a count of anything but real answers. Zero before the first advance.
  """
  @spec current_answers_count(GameSession.t()) :: non_neg_integer()
  def current_answers_count(%GameSession{} = session) do
    case current_question_id(session) do
      nil -> 0
      question_id -> question_id |> current_answers() |> Repo.aggregate(:count, :id)
    end
  end

  @doc """
  The ids of the participations that have already answered the question of the
  moment.

  It is what a screen needs to tell who the room is still waiting for, and it
  is scoped to the current question alone: an answer to a previous one says
  nothing about this one.
  """
  @spec answered_participant_ids(GameSession.t()) :: MapSet.t(integer())
  def answered_participant_ids(%GameSession{} = session) do
    case current_question_id(session) do
      nil ->
        MapSet.new()

      question_id ->
        question_id
        |> current_answers()
        |> select([a], a.participant_id)
        |> Repo.all()
        |> MapSet.new()
    end
  end

  @doc """
  Ends the match by the host's own decision.

  Allowed at any point of a running match — with a question open, with one
  closed, or before the first advance — because finishing is the host's call
  and never a consequence of the questions running out.

  The match becomes `finished` with `finished_at` stamped and everybody
  released for another room in a single statement, the very ending phase 2
  gives a cancelled room (AD-22). `current_question_position` is left where it
  was: it is the record of the last question actually played.

  Idempotent for the host: a match already finished is given back without a
  second `{:game_finished, session}`. A room still in the lobby, cancelled or
  expired answers `:invalid_status` — there is nothing running to end.
  """
  @spec finish_game_session(Scope.t(), GameSession.t()) ::
          {:ok, GameSession.t()} | {:error, :unauthorized | :invalid_status}
  def finish_game_session(%Scope{} = scope, %GameSession{} = session) do
    case fetch_hosted_session(scope, session) do
      {:ok, %GameSession{status: :finished} = finished} -> {:ok, finished}
      {:ok, %GameSession{} = current} -> finish_and_announce(current)
      {:error, :unauthorized} = error -> error
    end
  end

  @doc """
  Fetches one immutable result for its host or for the participant it belongs to.

  A participant can never use its identity to read another participant's result;
  callers that are not part of the match receive the same not-found response as
  an unknown result.
  """
  @spec get_game_result(Scope.t() | Participant.t() | nil, integer(), integer()) ::
          {:ok, GameResult.t()} | {:error, :not_found}
  def get_game_result(identity, session_id, participant_id)
      when is_integer(session_id) and is_integer(participant_id) do
    query =
      from r in GameResult,
        where: r.game_session_id == ^session_id and r.participant_id == ^participant_id,
        preload: [:game_session, :participant]

    case Repo.one(query) do
      %GameResult{} = result ->
        if result_visible_to?(result, identity), do: {:ok, result}, else: {:error, :not_found}

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Fetches a participant's own result by its stable result identifier."
  @spec get_my_game_result(Scope.t(), integer() | String.t()) ::
          {:ok, GameResult.t()} | {:error, :not_found}
  def get_my_game_result(%Scope{} = scope, id) do
    query =
      from r in GameResult,
        where: r.id == ^id and r.user_id == ^scope.user.id,
        preload: [:game_session, :participant]

    case Repo.one(query) do
      %GameResult{} = result -> {:ok, result}
      nil -> {:error, :not_found}
    end
  end

  @doc "Lists the finished results belonging to the authenticated participant."
  @spec list_game_results(Scope.t(), map() | keyword(), map() | keyword()) :: map()
  def list_game_results(%Scope{} = scope, filters, pagination) do
    query =
      from r in GameResult,
        join: s in assoc(r, :game_session),
        where: r.user_id == ^scope.user.id and s.status == :finished

    query
    |> result_filters(filters)
    |> paginate_results(pagination)
  end

  @doc "Lists finished matches hosted for quizzes owned by the authenticated user."
  @spec list_quiz_game_history(Scope.t(), integer(), map() | keyword(), map() | keyword()) ::
          map()
  def list_quiz_game_history(%Scope{} = scope, quiz_id, filters, pagination)
      when is_integer(quiz_id) do
    query =
      from s in GameSession,
        join: q in assoc(s, :quiz),
        where: s.host_id == ^scope.user.id and s.quiz_id == ^quiz_id and s.status == :finished,
        left_join: r in assoc(s, :game_results),
        group_by: [s.id, q.id],
        select: %{session: s, quiz_title: s.quiz_title, participants_count: count(r.id)}

    query
    |> session_result_filters(filters)
    |> paginate_sessions(pagination)
  end

  @doc """
  The state of the match as the viewer is allowed to see it.

  One read rebuilds a whole screen — where the match is, what the current
  question says, when it ends and what was chosen — so a connection that comes
  back asks for this and nothing else. It always reads the database, never a
  cached struct: the match state has a single source of truth.

  `viewer` decides the shape, and the choice is made here rather than in the
  presentation layer so that the web and the API cannot drift apart. The host
  always gets the answer key, plus `answers_count` — how many people have
  answered the question of the moment, which is the only thing about the
  answers a question still open gives away. The distribution by alternative
  waits for the question to close and lives in `question_results/3`, so nobody
  is nudged into voting with the crowd. Everybody else gets `correct: nil`
  while the question is open and the real key once it closes (AD-46), plus
  `my_answer_option_id` with their own choice.

  Only the host and the people who took part may look; anybody else gets
  `:unauthorized`. Being released — which finishing the match does to
  everybody — does not take the ending screen away from whoever played.

  `seconds_left` is a courtesy for a single reading and ages the instant it is
  sent; a countdown on screen must be drawn from `ends_at`, the server's
  absolute deadline (AD-39).

      %{
        status: :in_progress,
        question_number: 2,
        question_count: 10,
        question_state: :open,
        question_text: "Qual é a capital do Brasil?",
        ends_at: ~U[2026-09-05 18:04:30.000000Z],
        seconds_left: 22,
        last_question?: false,
        options: [%{id: 41, position: 1, text: "São Paulo", correct: nil}],
        my_answer_option_id: 42
      }

  The host's shape carries `answers_count: 17` where the playing one carries
  `my_answer_option_id`.
  """
  @spec game_state(GameSession.t(), Scope.t() | Participant.t()) ::
          {:ok, map()} | {:error, :unauthorized}
  def game_state(%GameSession{} = session, viewer) do
    current = reload_session(session)

    if allowed_to_watch?(current, viewer) do
      {:ok, build_game_state(current, viewer)}
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  The tally of a question that has closed: answer key, distribution and absences.

  This is what everybody sees at the reveal, and it is the same reading for the
  host and for whoever played — the only difference is that a participant also
  learns what they had picked and whether it was right.

  The distribution is aggregated by the database and the alternatives come from
  the snapshot, so one nobody chose is listed with `count: 0` instead of
  disappearing from the screen (AD-43), and the order is always the snapshot's.
  `is_correct` is the frozen answer key (AD-36) and never a reading of the quiz,
  which is why a match whose quiz was deleted tallies just the same.

  "No answer" is a difference, never a row: `participants_count` counts the
  active participations of the match — whoever left on purpose is out, whoever
  merely dropped off is in, because they are still someone who did not answer —
  and what is left after the answers is `no_answer_count`. Both numbers are read
  in a single statement, so somebody leaving in the middle cannot produce a
  tally that does not add up.

  Only a question the match is done with is tallied. While it is open — and
  while the match has not reached it — the answer is `{:error, :question_open}`,
  so neither a screen nor an endpoint can reveal the key ahead of time (AD-46).
  A position that was never frozen is `:not_found`, and anybody who is neither
  the host nor a participant is `:unauthorized`.

      %{
        position: 2,
        question_count: 10,
        question_text: "Qual é a capital do Brasil?",
        answers_count: 22,
        no_answer_count: 3,
        participants_count: 25,
        options: [
          %{id: 41, position: 1, text: "São Paulo", is_correct: false, count: 4},
          %{id: 42, position: 2, text: "Brasília", is_correct: true, count: 15},
          %{id: 43, position: 3, text: "Rio de Janeiro", is_correct: false, count: 3},
          %{id: 44, position: 4, text: "Salvador", is_correct: false, count: 0}
        ],
        my_answer_option_id: 42,
        my_answer_correct?: true
      }

  `my_answer_option_id` and `my_answer_correct?` are `nil` for the host and for
  whoever did not answer. There is no score, no speed bonus and no position
  here: phase 4 computes those on top of exactly these numbers.
  """
  @spec question_results(GameSession.t(), pos_integer(), Scope.t() | Participant.t()) ::
          {:ok, map()} | {:error, :question_open | :not_found | :unauthorized}
  def question_results(%GameSession{} = session, position, viewer) when is_integer(position) do
    current = reload_session(session)

    with :ok <- ensure_allowed_to_watch(current, viewer),
         {:ok, question} <- get_snapshot_question(current, position),
         :ok <- ensure_question_settled(current, position) do
      {:ok, build_question_results(current, question, viewer)}
    end
  end

  @doc """
  What a match adds up to: how far it got and how much was answered.

  `questions_played` is the position the match reached, which is the number of
  questions actually applied — a match finished on question 7 of 10 played
  seven. `answers_count` is every answer of the match, one per participation and
  question (AD-41), so a swap counts once.

  It reads the match wherever it is: asking in the middle brings what has been
  played so far, and the ending screen asks for it once the match is over. Only
  the host and the people who took part may read it.
  """
  @spec game_summary(GameSession.t(), Scope.t() | Participant.t()) ::
          {:ok, map()} | {:error, :unauthorized}
  def game_summary(%GameSession{} = session, viewer) do
    current = reload_session(session)

    case ensure_allowed_to_watch(current, viewer) do
      :ok -> {:ok, build_game_summary(current)}
      {:error, :unauthorized} = error -> error
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
  def cancel_game_session(%Scope{} = scope, %GameSession{} = session) do
    case fetch_hosted_session(scope, session) do
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
      {0, _unchanged} -> {:ok, reload_session(session)}
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
           set: [host_disconnected_at: nil, expires_at: nil, updated_at: now()]
         ) do
      {1, [updated]} -> {:ok, updated}
      {0, _unchanged} -> {:ok, reload_session(session)}
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
    |> live()
    |> order_by([s], asc: s.expires_at, asc: s.id)
    |> Repo.all()
  end

  @doc """
  How many seconds are left before the room expires, for the countdown the
  lobby shows.

  Answers `nil` when no deadline is running — the host is present — and `0`
  once the deadline is past, so the caller never has to reason about negative
  time.
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
    if allowed_to_list?(session, viewer) do
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

  @doc "The PubSub topic every event of a room is published on."
  @spec topic(integer()) :: String.t()
  def topic(session_id), do: "#{@topic_prefix}#{session_id}"

  @doc """
  Reads the room back out of a topic built by `topic/1`.

  Answers `:error` for anything else, so a presence diff on a topic this
  context did not build is ignored instead of crashing the tracker.
  """
  @spec session_id_from_topic(String.t()) :: {:ok, integer()} | :error
  def session_id_from_topic(@topic_prefix <> id) do
    case Integer.parse(id) do
      {id, ""} -> {:ok, id}
      _not_an_id -> :error
    end
  end

  def session_id_from_topic(_topic), do: :error

  @doc """
  Subscribes the calling process to the events of a room.

  A LiveView calls it in the connected mount and nowhere else: subscribing in
  the disconnected mount would leave the static render holding a subscription
  no process is going to consume.
  """
  @spec subscribe(integer()) :: :ok | {:error, term()}
  def subscribe(session_id), do: Phoenix.PubSub.subscribe(LiveQuiz.PubSub, topic(session_id))

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
      broadcast(session_id, {:host_disconnected, expires_at})
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
        broadcast(session_id, {:host_connected, nil})
        {:ok, session}

      nil ->
        :ignored
    end
  end

  # The single place an event leaves this module, always after the transaction
  # that produced it (AD-31).
  defp broadcast(session_id, event) do
    Phoenix.PubSub.broadcast(LiveQuiz.PubSub, topic(session_id), event)
  end

  defp fetch_live_session(session_id) do
    GameSession
    |> where([s], s.id == ^session_id)
    |> live()
    |> Repo.one()
  end

  defp ensure_playable(%Quiz{} = quiz) do
    if Quizzes.playable?(quiz), do: :ok, else: {:error, :quiz_not_playable}
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
    |> live()
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
    lock_identity(scope.user.id)

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
    lock_seats(session.id)

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
      joined_at: now()
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
    lock_identity(user_id)

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

  # Every room decision by a host reads the room back through the scope, so
  # somebody who does not host it is refused instead of acting on it, and a
  # stale struct cannot smuggle a transition past the check either.
  defp fetch_hosted_session(%Scope{} = scope, %GameSession{id: id}) do
    scope
    |> hosted_sessions()
    |> where([s], s.id == ^id)
    |> Repo.one()
    |> case do
      nil -> {:error, :unauthorized}
      %GameSession{} = session -> {:ok, session}
    end
  end

  defp start_and_announce(%Scope{} = scope, %GameSession{} = session, connected_count) do
    with :ok <- ensure_startable(session, connected_count),
         {:ok, outcome} <- freeze_and_go_live(scope, session) do
      case outcome do
        # Somebody else's start committed while this one waited for the row:
        # the match is running and has its single snapshot, and announcing it
        # again would replay the beginning for everyone listening.
        {:already_started, running} -> {:ok, running}
        {:started, started} -> announce_start(started)
      end
    end
  end

  defp announce_start(%GameSession{} = session) do
    broadcast(session.id, {:game_started, session})
    {:ok, session}
  end

  defp ensure_startable(%GameSession{status: :waiting}, connected_count) do
    if connected_count > 0, do: :ok, else: {:error, :no_connected_participants}
  end

  defp ensure_startable(%GameSession{}, _connected_count), do: {:error, :invalid_transition}

  # The snapshot and the transition share one transaction (AD-36), opened by
  # locking the room's own row: whoever comes second waits there and finds the
  # match already running instead of writing a second snapshot over the unique
  # index of `(game_session_id, position)`.
  defp freeze_and_go_live(%Scope{} = scope, %GameSession{id: id}) do
    Repo.transaction(fn ->
      case lock_session(id) do
        %GameSession{status: :waiting} = session ->
          freeze_quiz_into(scope, session)

        %GameSession{status: :in_progress} = session ->
          {:already_started, session}

        _over_or_gone ->
          Repo.rollback(:invalid_transition)
      end
    end)
  end

  defp freeze_quiz_into(%Scope{} = scope, %GameSession{} = session) do
    with {:ok, quiz} <- fetch_quiz_to_freeze(scope, session),
         :ok <- ensure_playable(quiz),
         :ok <- write_snapshot(session, quiz.questions),
         {:ok, started} <- go_live(session) do
      {:started, started}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # The quiz is nullified out of the room when it is deleted, so a room with no
  # `quiz_id` is one whose quiz is already gone and needs no query to know it.
  defp fetch_quiz_to_freeze(%Scope{}, %GameSession{quiz_id: nil}), do: {:error, :quiz_unavailable}

  defp fetch_quiz_to_freeze(%Scope{} = scope, %GameSession{quiz_id: quiz_id}) do
    case Quizzes.fetch_quiz_with_questions(scope, quiz_id) do
      {:ok, %Quiz{} = quiz} -> {:ok, quiz}
      :error -> {:error, :quiz_unavailable}
    end
  end

  # Two `insert_all/3` rather than a row at a time: a full quiz is a hundred
  # options, and a hundred round trips would hold the room's row locked for no
  # reason. The options need the ids the database just handed out, so the
  # questions come back with `position` as well — the order rows are returned in
  # is not guaranteed, and the position is what correlates them.
  defp write_snapshot(%GameSession{id: session_id}, questions) do
    at = now()
    questions = Enum.sort_by(questions, & &1.position)

    {_inserted, snapshot_questions} =
      Repo.insert_all(GameSessionQuestion, snapshot_question_rows(session_id, questions, at),
        returning: [:id, :position]
      )

    ids_by_position = Map.new(snapshot_questions, &{&1.position, &1.id})

    Repo.insert_all(
      GameSessionAnswerOption,
      snapshot_option_rows(questions, ids_by_position, at)
    )

    :ok
  end

  # Positions are handed out from 1 with no gaps, whatever the quiz looked like:
  # a quiz whose question 2 was deleted freezes as 1 and 2, and the execution
  # can walk the match by counting instead of hunting for the next position.
  defp snapshot_question_rows(session_id, questions, at) do
    questions
    |> Enum.with_index(1)
    |> Enum.map(fn {question, position} ->
      %{
        game_session_id: session_id,
        question_id: question.id,
        position: position,
        question_text: question.text,
        inserted_at: at,
        updated_at: at
      }
    end)
  end

  defp snapshot_option_rows(questions, ids_by_position, at) do
    questions
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {question, position} ->
      snapshot_question_id = Map.fetch!(ids_by_position, position)

      question.answer_options
      |> Enum.sort_by(& &1.position)
      |> Enum.with_index(1)
      |> Enum.map(fn {option, option_position} ->
        %{
          game_session_question_id: snapshot_question_id,
          original_answer_option_id: option.id,
          text: option.text,
          position: option_position,
          is_correct: option.is_correct,
          inserted_at: at,
          updated_at: at
        }
      end)
    end)
  end

  # The status in the `WHERE` is the actual guard, not the check above it: the
  # room only goes live if the database still sees it waiting, so a second
  # caller updates no row and is told the transition is invalid.
  defp go_live(%GameSession{id: id}) do
    at = now()

    query = from s in GameSession, where: s.id == ^id and s.status == :waiting, select: s

    case Repo.update_all(query, set: [status: :in_progress, started_at: at, updated_at: at]) do
      {1, [session]} -> {:ok, session}
      {0, _unchanged} -> {:error, :invalid_transition}
    end
  end

  defp lock_session(id) do
    GameSession |> where([s], s.id == ^id) |> lock("FOR UPDATE") |> Repo.one()
  end

  defp snapshot_questions(session_id) do
    where(GameSessionQuestion, [q], q.game_session_id == ^session_id)
  end

  # Every command that moves a match takes the advisory lock on the room first,
  # so two clicks of the same host take turns while every other room carries on
  # untouched. The lock lasts the transaction; the `WHERE` of each `UPDATE` is
  # still what decides, so a command that lost the race changes no row and is
  # told why instead of overwriting the winner.
  defp open_next_question(%GameSession{id: id}, expected_position) do
    Repo.transaction(fn ->
      lock_match(id)

      with {:ok, running} <- ensure_running(Repo.get(GameSession, id)),
           :ok <- ensure_current_position(running, expected_position),
           {:ok, position} <- next_position(running),
           :ok <- close_open_question(running),
           {:ok, advanced} <- open_question(running, position) do
        advanced
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp close_current_question(%GameSession{id: id}) do
    Repo.transaction(fn ->
      lock_match(id)

      case ensure_running(Repo.get(GameSession, id)) do
        {:ok, %GameSession{current_question_position: nil}} ->
          Repo.rollback(:no_open_question)

        {:ok, %GameSession{current_question_closed_at: at} = closed} when not is_nil(at) ->
          {:already_closed, closed}

        {:ok, %GameSession{} = open} ->
          close_now(open)

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  # The same lock and the same statement the host's closing takes, so the two
  # take turns and the loser writes nothing. The deadline is read inside the
  # transaction rather than trusted from the caller: a timer only knows when it
  # was armed, the row knows when the question actually ends.
  defp close_due_question(session_id) do
    Repo.transaction(fn ->
      lock_match(session_id)

      case Repo.get(GameSession, session_id) do
        nil -> Repo.rollback(:not_found)
        %GameSession{} = session -> close_if_due(session)
      end
    end)
  end

  defp close_if_due(%GameSession{} = session) do
    case ensure_running(session) do
      {:error, reason} ->
        Repo.rollback(reason)

      {:ok, %GameSession{current_question_position: nil}} ->
        Repo.rollback(:no_open_question)

      {:ok, %GameSession{current_question_closed_at: at} = closed} when not is_nil(at) ->
        {:already_closed, closed}

      {:ok, %GameSession{} = open} ->
        if question_due?(open), do: close_now(open), else: Repo.rollback(:not_due)
    end
  end

  defp question_due?(%GameSession{current_question_ends_at: nil}), do: false

  defp question_due?(%GameSession{current_question_ends_at: ends_at}) do
    DateTime.compare(DateTime.utc_now(), ends_at) != :lt
  end

  defp close_now(%GameSession{} = session) do
    case stamp_question_closed(session) do
      {1, [closed]} -> {:closed, closed}
      {0, _unchanged} -> {:already_closed, reload_session(session)}
    end
  end

  # The whole chain runs in one transaction under the advisory lock of the room,
  # which is what lets the decision to close the question be taken from the very
  # count this answer produced (AD-42) and what makes it take turns with the
  # host's own commands. Nothing is written until every check has passed, so a
  # refusal leaves no trace.
  defp record_answer(
         %Participant{game_session_id: session_id} = participant,
         option_id,
         connected
       ) do
    Repo.transaction(fn ->
      lock_match(session_id)

      with {:ok, session} <- ensure_running(Repo.get(GameSession, session_id)),
           :ok <- ensure_taking_answers(session),
           {:ok, playing} <- ensure_still_playing(participant),
           {:ok, question_id, chosen_id} <- fetch_current_option(session, option_id) do
        upsert_answer(session, question_id, playing, chosen_id, connected)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Taking answers is a question already advanced to, not yet closed and still
  # inside its deadline (AD-37). The three refusals are told apart because a
  # screen has a different thing to say for each one.
  defp ensure_taking_answers(%GameSession{current_question_position: nil}),
    do: {:error, :no_open_question}

  defp ensure_taking_answers(%GameSession{current_question_closed_at: at}) when not is_nil(at),
    do: {:error, :question_closed}

  defp ensure_taking_answers(%GameSession{current_question_ends_at: ends_at}) do
    # The deadline of the database is the only clock consulted (AD-39): the
    # instant the client believes in never reaches here.
    if DateTime.compare(now_usec(), ends_at) == :gt, do: {:error, :time_is_up}, else: :ok
  end

  # The participation is read back rather than trusted from the struct that
  # arrived, so a screen left open since before the person walked out cannot
  # answer on their behalf.
  defp ensure_still_playing(%Participant{id: id}) do
    Participant
    |> where([p], p.id == ^id and is_nil(p.left_at) and is_nil(p.released_at))
    |> Repo.one()
    |> case do
      nil -> {:error, :left_session}
      %Participant{} = participant -> {:ok, participant}
    end
  end

  # The option is matched against the current question of this very match, so
  # the id of an option of another question — or of another room altogether —
  # is refused instead of being written. The question comes back from the same
  # query: there is no id worth trusting here.
  defp fetch_current_option(%GameSession{} = session, option_id) do
    query =
      from o in GameSessionAnswerOption,
        join: q in GameSessionQuestion,
        on: q.id == o.game_session_question_id,
        where: o.id == ^option_id,
        where: q.game_session_id == ^session.id,
        where: q.position == ^session.current_question_position,
        select: {q.id, o.id}

    case Repo.one(query) do
      nil -> {:error, :option_not_found}
      {question_id, chosen_id} -> {:ok, question_id, chosen_id}
    end
  end

  # `inserted_at` is deliberately out of the replace list: it records when the
  # person first answered this question, and rewriting it would hand phase 4 the
  # instant of the last swap as if it were the first choice.
  defp upsert_answer(session, question_id, participant, chosen_id, connected) do
    answer =
      %Answer{}
      |> Answer.changeset(%{
        game_session_id: session.id,
        game_session_question_id: question_id,
        participant_id: participant.id,
        game_session_answer_option_id: chosen_id,
        answered_at: now_usec()
      })
      |> Repo.insert!(
        on_conflict: {:replace, [:game_session_answer_option_id, :answered_at, :updated_at]},
        conflict_target: [:participant_id, :game_session_question_id],
        returning: true
      )

    count = question_id |> current_answers() |> Repo.aggregate(:count, :id)
    {session, closed?} = close_if_everybody_answered(session, count, connected)

    %{answer: answer, session: session, closed?: closed?, count: count}
  end

  # With nobody connected there is nothing to complete, so the rule never fires
  # and the question runs to its deadline or waits for the host. The count is
  # the one taken inside the transaction, which is what makes "I was the last
  # one missing" a fact instead of a guess.
  defp close_if_everybody_answered(%GameSession{} = session, _count, 0), do: {session, false}

  defp close_if_everybody_answered(%GameSession{} = session, count, connected)
       when count >= connected do
    case close_now(session) do
      {:closed, closed} -> {closed, true}
      {:already_closed, closed} -> {closed, false}
    end
  end

  defp close_if_everybody_answered(%GameSession{} = session, _count, _connected),
    do: {session, false}

  defp current_answers(question_id) do
    where(Answer, [a], a.game_session_question_id == ^question_id)
  end

  defp current_question_id(%GameSession{current_question_position: nil}), do: nil

  defp current_question_id(%GameSession{id: id, current_question_position: position}) do
    id
    |> snapshot_questions()
    |> where([q], q.position == ^position)
    |> select([q], q.id)
    |> Repo.one()
  end

  defp finish_and_announce(%GameSession{} = session) do
    case finish_match(session) do
      {:ok, {:finished, finished}} ->
        QuestionTimer.stop(finished.id)
        broadcast(finished.id, {:game_finished, finished})
        {:ok, finished}

      # Another finish committed while this one waited for the lock. The match
      # is over and was announced once; saying so twice would replay the ending.
      {:ok, {:already_finished, finished}} ->
        QuestionTimer.stop(finished.id)
        {:ok, finished}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The ending phase 2 already writes for a cancelled room, with one difference:
  # only a running match may be finished, so a room still in the lobby is
  # refused instead of being closed as if it had been played. Losing the race to
  # another finish is not a failure — the match is over either way.
  defp finish_match(%GameSession{id: id}) do
    at = now()

    query = from s in GameSession, where: s.id == ^id and s.status == :in_progress, select: s

    Repo.transaction(fn ->
      lock_match(id)

      case Repo.update_all(query,
             set: [status: :finished, finished_at: at, expires_at: nil, updated_at: at]
           ) do
        {1, [finished]} ->
          persist_final_results(finished)
          release_participants(id, at)
          {:finished, finished}

        {0, _unchanged} ->
          rollback_unless_finished(id)
      end
    end)
  end

  defp rollback_unless_finished(id) do
    case Repo.get(GameSession, id) do
      %GameSession{status: :finished} = finished -> {:already_finished, finished}
      _lobby_or_closed -> Repo.rollback(:invalid_status)
    end
  end

  defp persist_final_results(%GameSession{} = session) do
    participants = ranking_participants(session.id)

    participants
    |> Enum.with_index(1)
    |> Enum.each(fn {participant, position} ->
      Repo.update_all(
        from(p in Participant, where: p.id == ^participant.id),
        set: [final_position: position, updated_at: now()]
      )
    end)

    questions = snapshot_questions(session.id) |> preload(:answer_options) |> Repo.all()
    answers = Repo.all(from a in Answer, where: a.game_session_id == ^session.id)
    answer_by_participant = Enum.group_by(answers, & &1.participant_id)

    rows =
      Enum.map(Enum.with_index(participants, 1), fn {participant, position} ->
        participant_answers = Map.get(answer_by_participant, participant.id, [])
        answered_count = length(participant_answers)

        %{
          game_session_id: session.id,
          participant_id: participant.id,
          user_id: participant.user_id,
          quiz_id: session.quiz_id,
          quiz_title: session.quiz_title,
          nickname: participant.nickname,
          score: participant.score,
          correct_answers: participant.correct_answers,
          incorrect_answers: participant.incorrect_answers,
          unanswered_questions: max(length(questions) - answered_count, 0),
          answered_questions: answered_count,
          total_response_time_ms: participant.total_response_time_ms,
          average_response_time_ms: average_response_time(participant, answered_count),
          final_position: position,
          question_results: question_result_snapshot(questions, participant_answers),
          inserted_at: now(),
          updated_at: now()
        }
      end)

    Repo.insert_all(GameResult, rows,
      on_conflict: :nothing,
      conflict_target: [:game_session_id, :participant_id]
    )
  end

  defp average_response_time(_participant, 0), do: 0

  defp average_response_time(%Participant{total_response_time_ms: total}, answered_count),
    do: div(total, answered_count)

  defp question_result_snapshot(questions, answers) do
    answers_by_question = Map.new(answers, &{&1.game_session_question_id, &1})

    Map.new(questions, fn question ->
      answer = Map.get(answers_by_question, question.id)

      chosen =
        answer &&
          Enum.find(question.answer_options, &(&1.id == answer.game_session_answer_option_id))

      key = Integer.to_string(question.position)

      {key,
       %{
         "question" => question.question_text,
         "options" =>
           Enum.map(question.answer_options, fn option ->
             %{
               "position" => option.position,
               "text" => option.text,
               "correct" => option.is_correct
             }
           end),
         "answer_option_id" => answer && answer.game_session_answer_option_id,
         "answer" => chosen && chosen.text,
         "correct" => chosen && chosen.is_correct,
         "answered_at" => answer && DateTime.to_iso8601(answer.answered_at),
         "response_time_ms" => 0
       }}
    end)
  end

  defp result_visible_to?(%GameResult{game_session: %GameSession{host_id: host_id}}, %Scope{
         user: %User{id: host_id}
       }),
       do: true

  defp result_visible_to?(%GameResult{participant_id: participant_id}, %Participant{
         id: participant_id
       }),
       do: true

  defp result_visible_to?(%GameResult{user_id: user_id}, %Scope{user: %User{id: user_id}}),
    do: true

  defp result_visible_to?(_result, _identity), do: false

  defp result_filters(query, filters) do
    filters = Map.new(filters)

    query
    |> maybe_filter_quiz(Map.get(filters, :quiz_id) || Map.get(filters, "quiz_id"))
    |> maybe_filter_date(:inserted_at, Map.get(filters, :from) || Map.get(filters, "from"), :>=)
    |> maybe_filter_date(:inserted_at, Map.get(filters, :to) || Map.get(filters, "to"), :<=)
  end

  defp session_result_filters(query, filters) do
    filters = Map.new(filters)

    query
    |> maybe_filter_session_date(Map.get(filters, :from) || Map.get(filters, "from"), :>=)
    |> maybe_filter_session_date(Map.get(filters, :to) || Map.get(filters, "to"), :<=)
  end

  defp maybe_filter_quiz(query, nil), do: query
  defp maybe_filter_quiz(query, quiz_id), do: where(query, [r, _s], r.quiz_id == ^quiz_id)

  defp maybe_filter_date(query, _field, nil, _operator), do: query

  defp maybe_filter_date(query, field, value, operator) do
    case parse_filter_date(value) do
      {:ok, datetime} ->
        case operator do
          :>= -> where(query, [r, _s], field(r, ^field) >= ^datetime)
          :<= -> where(query, [r, _s], field(r, ^field) <= ^datetime)
        end

      :error ->
        query
    end
  end

  defp maybe_filter_session_date(query, nil, _operator), do: query

  defp maybe_filter_session_date(query, value, operator) do
    case parse_filter_date(value) do
      {:ok, datetime} ->
        case operator do
          :>= -> where(query, [s, _q, _r], s.finished_at >= ^datetime)
          :<= -> where(query, [s, _q, _r], s.finished_at <= ^datetime)
        end

      :error ->
        query
    end
  end

  defp paginate_results(query, pagination) do
    pagination = Map.new(pagination)
    page = normalize_result_page(Map.get(pagination, :page) || Map.get(pagination, "page"))

    per_page =
      normalize_result_per_page(Map.get(pagination, :per_page) || Map.get(pagination, "per_page"))

    total = Repo.aggregate(query, :count, :id)

    %{
      entries:
        Repo.all(
          from r in query,
            order_by: [desc: r.inserted_at, desc: r.id],
            limit: ^per_page,
            offset: ^((page - 1) * per_page)
        ),
      page: page,
      per_page: per_page,
      total_entries: total,
      total_pages: ceil(total / per_page)
    }
  end

  defp paginate_sessions(query, pagination) do
    pagination = Map.new(pagination)
    page = normalize_result_page(Map.get(pagination, :page) || Map.get(pagination, "page"))

    per_page =
      normalize_result_per_page(Map.get(pagination, :per_page) || Map.get(pagination, "per_page"))

    total = query |> Repo.all() |> length()

    entries =
      query
      |> order_by([s, _q, _r], desc: s.finished_at, desc: s.id)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    %{
      entries: entries,
      page: page,
      per_page: per_page,
      total_entries: total,
      total_pages: ceil(total / per_page)
    }
  end

  defp parse_filter_date(%DateTime{} = value), do: {:ok, value}

  defp parse_filter_date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> :error
    end
  end

  defp parse_filter_date(_value), do: :error

  defp normalize_result_page(value) when is_integer(value) and value > 0, do: value

  defp normalize_result_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page > 0 -> page
      _ -> 1
    end
  end

  defp normalize_result_page(_value), do: 1

  defp normalize_result_per_page(value) when is_integer(value) and value in 1..100, do: value

  defp normalize_result_per_page(value) when is_binary(value),
    do: value |> Integer.parse() |> normalize_result_per_page()

  defp normalize_result_per_page({per_page, ""}) when per_page in 1..100, do: per_page
  defp normalize_result_per_page(_value), do: 20

  defp ensure_running(%GameSession{status: :in_progress} = session), do: {:ok, session}
  defp ensure_running(_over_or_gone), do: {:error, :invalid_status}

  # Comparing the position the caller believes is current is the whole
  # protection against a double command (AD-44): a flag would be reset by the
  # winner and let the loser through, while a position that already moved never
  # matches again.
  defp ensure_current_position(%GameSession{current_question_position: position}, position),
    do: :ok

  defp ensure_current_position(%GameSession{}, _expected_position), do: {:error, :stale}

  defp next_position(%GameSession{current_question_position: current} = session) do
    position = (current || 0) + 1

    if position <= snapshot_question_count(session) do
      {:ok, position}
    else
      {:error, :no_more_questions}
    end
  end

  # The question being left behind is closed inside the transaction that opens
  # the next one: leaving it out would record a question that started and never
  # ended, and phase 4 reads that ending.
  defp close_open_question(%GameSession{} = session) do
    if GameSession.question_open?(session), do: stamp_question_closed(session)

    :ok
  end

  defp stamp_question_closed(%GameSession{id: id}) do
    at = now_usec()

    query =
      from s in GameSession,
        where: s.id == ^id,
        where: s.status == :in_progress,
        where: not is_nil(s.current_question_position),
        where: is_nil(s.current_question_closed_at),
        select: s

    Repo.update_all(query,
      set: [current_question_closed_at: at, updated_at: DateTime.truncate(at, :second)]
    )
  end

  # The position the match is leaving is repeated in the `WHERE`, so the second
  # of two simultaneous advances updates nothing and is answered `:stale`
  # instead of pushing the match one question further than the host asked for.
  defp open_question(%GameSession{} = session, position) do
    at = now_usec()
    ends_at = DateTime.add(at, session.question_duration_seconds, :second)

    query =
      from s in GameSession,
        where: s.id == ^session.id and s.status == :in_progress,
        select: s

    query = where_current_position(query, session.current_question_position)

    case Repo.update_all(query,
           set: [
             current_question_position: position,
             current_question_started_at: at,
             current_question_ends_at: ends_at,
             current_question_closed_at: nil,
             updated_at: DateTime.truncate(at, :second)
           ]
         ) do
      {1, [advanced]} -> {:ok, advanced}
      {0, _unchanged} -> {:error, :stale}
    end
  end

  defp where_current_position(query, nil) do
    where(query, [s], is_nil(s.current_question_position))
  end

  defp where_current_position(query, position) do
    where(query, [s], s.current_question_position == ^position)
  end

  defp build_game_state(%GameSession{} = session, viewer) do
    state = question_state(session)
    count = snapshot_question_count(session)
    question = current_snapshot_question(session, state)
    host? = host_view?(session, viewer)

    base = %{
      status: session.status,
      question_number: session.current_question_position,
      question_count: count,
      question_state: state,
      question_text: question && question.question_text,
      ends_at: session.current_question_ends_at,
      seconds_left: seconds_left(session, state),
      last_question?: last_question?(session, count),
      options: state_options(question, state, host?)
    }

    if host? do
      Map.put(base, :answers_count, current_answers_count(session))
    else
      Map.put(base, :my_answer_option_id, own_answer_option_id(session, question, viewer))
    end
  end

  defp build_question_results(
         %GameSession{} = session,
         %GameSessionQuestion{} = question,
         viewer
       ) do
    rows = option_distribution(session, question)
    options = Enum.map(rows, &Map.delete(&1, :participants_count))
    answers_count = Enum.reduce(options, 0, fn option, total -> total + option.count end)
    participants_count = participants_count(rows, session)
    {my_option_id, my_correct?} = own_result(session, question, viewer, options)

    %{
      position: question.position,
      question_count: snapshot_question_count(session),
      question_text: question.question_text,
      answers_count: answers_count,
      # Never negative: the denominator and the answers are read together, but a
      # participation that leaves between two tallies would otherwise make the
      # count of absences go below zero on the next reading.
      no_answer_count: max(participants_count - answers_count, 0),
      participants_count: participants_count,
      options: options,
      my_answer_option_id: my_option_id,
      my_answer_correct?: my_correct?
    }
  end

  # One statement for the distribution and for the denominator alike. The
  # `LEFT JOIN` is what keeps an alternative nobody picked in the list with zero
  # instead of dropping it (AD-43) — the most likely mistake of this reading —
  # and the cross join carries the count of active participations along, so the
  # two numbers describe the same instant.
  defp option_distribution(%GameSession{id: session_id}, %GameSessionQuestion{id: question_id}) do
    from(o in GameSessionAnswerOption,
      cross_join: p in subquery(active_participations(session_id)),
      left_join: a in Answer,
      on: a.game_session_answer_option_id == o.id,
      where: o.game_session_question_id == ^question_id,
      group_by: [o.id, p.count],
      order_by: [asc: o.position],
      select: %{
        id: o.id,
        position: o.position,
        text: o.text,
        is_correct: o.is_correct,
        count: count(a.id),
        participants_count: p.count
      }
    )
    |> Repo.all()
  end

  # Whoever left on purpose is out of the denominator; whoever merely dropped off
  # is in, because being disconnected is still not having answered.
  defp active_participations(session_id) do
    from p in Participant,
      where: p.game_session_id == ^session_id,
      where: is_nil(p.left_at),
      select: %{count: count(p.id)}
  end

  defp participants_count([%{participants_count: count} | _rest], %GameSession{}), do: count

  # A snapshot question always freezes its alternatives, so this only answers a
  # question stripped of them, and then the denominator still has to be right.
  defp participants_count([], %GameSession{id: session_id}) do
    %{count: count} = Repo.one(active_participations(session_id))
    count
  end

  defp own_result(%GameSession{} = session, %GameSessionQuestion{} = question, viewer, options) do
    with false <- host_view?(session, viewer),
         %Participant{} = participant <- viewer_participant(session, viewer),
         option_id when is_integer(option_id) <- chosen_option_id(participant, question) do
      {option_id, correct_option?(options, option_id)}
    else
      _host_or_no_answer -> {nil, nil}
    end
  end

  defp correct_option?(options, option_id) do
    Enum.any?(options, &(&1.id == option_id and &1.is_correct))
  end

  defp build_game_summary(%GameSession{id: id} = session) do
    %{count: participants_count} = Repo.one(active_participations(id))

    %{
      status: session.status,
      question_count: snapshot_question_count(session),
      questions_played: session.current_question_position || 0,
      answers_count: Repo.aggregate(where(Answer, [a], a.game_session_id == ^id), :count),
      participants_count: participants_count
    }
  end

  # A question the match has moved past is settled, and the one being played is
  # settled the moment it stops taking answers. A question the match has not
  # reached yet is not settled either: the answer key of question 5 is no more
  # public while the room plays question 2 than it is while it plays question 5.
  defp ensure_question_settled(%GameSession{current_question_position: nil}, _position),
    do: {:error, :question_open}

  defp ensure_question_settled(
         %GameSession{current_question_position: current} = session,
         position
       ) do
    cond do
      position < current -> :ok
      position > current -> {:error, :question_open}
      GameSession.question_open?(session) -> {:error, :question_open}
      true -> :ok
    end
  end

  defp ensure_allowed_to_watch(%GameSession{} = session, viewer) do
    if allowed_to_watch?(session, viewer), do: :ok, else: {:error, :unauthorized}
  end

  defp question_state(%GameSession{current_question_position: nil}), do: :pending

  defp question_state(%GameSession{} = session) do
    if GameSession.question_open?(session), do: :open, else: :closed
  end

  defp current_snapshot_question(%GameSession{}, :pending), do: nil

  defp current_snapshot_question(%GameSession{} = session, _state) do
    case get_snapshot_question(session, session.current_question_position) do
      {:ok, %GameSessionQuestion{} = question} -> question
      {:error, :not_found} -> nil
    end
  end

  defp state_options(nil, _state, _host?), do: []

  defp state_options(%GameSessionQuestion{} = question, state, host?) do
    Enum.map(question.answer_options, fn option ->
      %{
        id: option.id,
        position: option.position,
        text: option.text,
        correct: visible_answer_key(option, state, host?)
      }
    end)
  end

  # The answer key is the one thing a running question must not leak (AD-46):
  # while it is open, whoever is playing sees `nil` rather than a field that is
  # simply absent, so a client cannot tell "no key yet" from "wrong".
  defp visible_answer_key(%GameSessionAnswerOption{is_correct: correct}, _state, true),
    do: correct

  defp visible_answer_key(%GameSessionAnswerOption{}, :open, false), do: nil

  defp visible_answer_key(%GameSessionAnswerOption{is_correct: correct}, _state, false),
    do: correct

  defp seconds_left(%GameSession{}, :pending), do: nil
  defp seconds_left(%GameSession{current_question_ends_at: nil}, _state), do: nil
  defp seconds_left(%GameSession{}, :closed), do: 0

  defp seconds_left(%GameSession{current_question_ends_at: ends_at}, :open) do
    max(DateTime.diff(ends_at, DateTime.utc_now()), 0)
  end

  defp last_question?(%GameSession{current_question_position: nil}, _count), do: false

  defp last_question?(%GameSession{current_question_position: position}, count),
    do: position >= count

  defp host_view?(%GameSession{host_id: host_id}, %Scope{user: %User{id: host_id}}), do: true
  defp host_view?(%GameSession{}, _viewer), do: false

  defp own_answer_option_id(%GameSession{} = session, question, viewer) do
    with %GameSessionQuestion{} <- question,
         %Participant{} = participant <- viewer_participant(session, viewer) do
      chosen_option_id(participant, question)
    else
      _nothing_played_yet -> nil
    end
  end

  defp viewer_participant(%GameSession{}, %Participant{} = participant), do: participant

  defp viewer_participant(%GameSession{id: session_id}, %Scope{} = scope) do
    Participant
    |> where([p], p.game_session_id == ^session_id and p.user_id == ^scope.user.id)
    |> order_by([p], desc: p.id)
    |> limit(1)
    |> Repo.one()
  end

  defp chosen_option_id(%Participant{id: participant_id}, %GameSessionQuestion{id: question_id}) do
    Answer
    |> where([a], a.participant_id == ^participant_id)
    |> where([a], a.game_session_question_id == ^question_id)
    |> select([a], a.game_session_answer_option_id)
    |> Repo.one()
  end

  # Wider than `allowed_to_list?/2` on purpose: finishing a match releases
  # everybody, and the ending screen belongs to exactly the people who were
  # just released. Whose room it is never changes, so only somebody from
  # another room is turned away.
  defp allowed_to_watch?(%GameSession{} = session, %Scope{} = scope) do
    session.host_id == scope.user.id or took_part?(session, scope)
  end

  defp allowed_to_watch?(%GameSession{id: session_id}, %Participant{game_session_id: session_id}),
    do: true

  defp allowed_to_watch?(_session, _viewer), do: false

  defp took_part?(%GameSession{id: session_id}, %Scope{} = scope) do
    Participant
    |> where([p], p.game_session_id == ^session_id and p.user_id == ^scope.user.id)
    |> Repo.exists?()
  end

  # Both ways of closing a room share the transition and differ only in the
  # event they announce, which is what tells a lobby whether to say "cancelled"
  # or "expired". The broadcast is outside the transaction on purpose (AD-31).
  defp close_and_announce(%GameSession{} = session, status, event) do
    case close_session(session, status) do
      {:ok, session} ->
        QuestionTimer.stop(session.id)
        broadcast(session.id, {event, session})
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
    at = now()

    query =
      from s in GameSession,
        where: s.id == ^id and s.status in ^GameSession.active_statuses(),
        select: s

    Repo.transaction(fn ->
      case Repo.update_all(query,
             set: [status: status, finished_at: at, expires_at: nil, updated_at: at]
           ) do
        {1, [session]} ->
          release_participants(id, at)
          session

        {0, _unchanged} ->
          Repo.rollback(:invalid_transition)
      end
    end)
  end

  # One statement for the whole room. Only `released_at` is stamped: whoever was
  # there stays recorded as present at the end, which is what phase 4 reads back
  # as history, and clearing the one-room-per-account index violates nothing.
  defp release_participants(session_id, at) do
    Participant
    |> where([p], p.game_session_id == ^session_id and is_nil(p.released_at))
    |> Repo.update_all(set: [released_at: at, updated_at: at])
  end

  defp reload_session(%GameSession{id: id} = session) do
    Repo.get(GameSession, id) || session
  end

  defp same_connection?(current, presented) do
    is_binary(current) and is_binary(presented) and current == presented
  end

  defp allowed_to_list?(%GameSession{} = session, %Scope{} = scope) do
    session.host_id == scope.user.id or taking_part?(session, scope)
  end

  defp allowed_to_list?(%GameSession{id: session_id}, %Participant{
         game_session_id: session_id,
         released_at: nil
       }),
       do: true

  defp allowed_to_list?(_session, _viewer), do: false

  defp taking_part?(%GameSession{id: session_id}, %Scope{} = scope) do
    Participant
    |> where([p], p.game_session_id == ^session_id and p.user_id == ^scope.user.id)
    |> where([p], is_nil(p.released_at))
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

  # Serializes every room decision taken on behalf of one account. The lock is
  # released when the transaction ends, and it is taken before any read so the
  # checks below cannot race against a concurrent insert.
  defp lock_identity(user_id) do
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@identity_lock_class, user_id])
  end

  # Serializes the seat count of one room. Taken only after the identity lock,
  # so every story that touches both keeps the same order and cannot deadlock.
  defp lock_seats(session_id) do
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@seats_lock_class, session_id])
  end

  # Serializes the commands of one match. It is the only lock they take, so
  # there is no order to keep and no way for two of them to deadlock.
  defp lock_match(session_id) do
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@match_lock_class, session_id])
  end

  defp hosted_sessions(%Scope{} = scope) do
    from s in GameSession, where: s.host_id == ^scope.user.id
  end

  defp live(query) do
    where(query, [s], s.status in ^GameSession.active_statuses())
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)

  # The execution columns keep the fraction of a second the phase 4 speed bonus
  # measures, so they are never truncated the way the phase 2 columns are.
  defp now_usec, do: DateTime.utc_now()
end
