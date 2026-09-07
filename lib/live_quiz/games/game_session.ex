defmodule LiveQuiz.Games.GameSession do
  @moduledoc """
  A single run of a quiz: the room a host opens and participants join.

  The room keeps `quiz_title` copied from the quiz it was created from, so it
  stays readable as history even after the quiz is deleted — `quiz_id` is
  nullified rather than cascaded. This is not the question snapshot, which
  belongs to phase 3.

  Deleting a room removes its participants through the database cascade declared
  in the migration, so the association below intentionally does not carry
  `:on_delete`.

  The rules that several connections dispute at the same time — a unique code
  among live rooms and a single live room per host — are enforced by partial
  unique indexes; the changesets below only translate their violations into
  pt-BR messages.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias LiveQuiz.Accounts.User
  alias LiveQuiz.Changesets
  alias LiveQuiz.Games.GameResult
  alias LiveQuiz.Games.GameSessionQuestion
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Quizzes.Quiz

  @type t :: %__MODULE__{}

  @statuses [:waiting, :in_progress, :finished, :cancelled, :expired]
  @active_statuses [:waiting, :in_progress]
  @closed_statuses [:finished, :cancelled, :expired]
  @question_durations [10, 20, 30, 60]
  @join_code_length 6
  @join_code_alphabet "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
  @join_code_regex ~r/^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{6}$/

  schema "game_sessions" do
    field :public_id, Ecto.UUID
    field :quiz_title, :string
    field :join_code, :string
    field :status, Ecto.Enum, values: @statuses, default: :waiting
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :host_connection_id, Ecto.UUID
    field :host_disconnected_at, :utc_datetime
    field :expires_at, :utc_datetime

    # The state of the current question is derived from these columns instead of
    # living in an enum of its own (AD-37): open is a position filled with no
    # `current_question_closed_at`, closed is that instant stamped. They are
    # `utc_datetime_usec` while the phase 2 columns above are second-precision —
    # deliberate, not an oversight: the speed bonus of phase 4 needs the
    # fraction, and rounding it would tie half the room.
    field :question_duration_seconds, :integer, default: 30
    field :current_question_position, :integer
    field :current_question_started_at, :utc_datetime_usec
    field :current_question_ends_at, :utc_datetime_usec
    field :current_question_closed_at, :utc_datetime_usec

    # Filled in by the context (F2-03), never read from the database.
    field :participants_count, :integer, virtual: true
    field :connected_count, :integer, virtual: true

    belongs_to :quiz, Quiz
    belongs_to :host, User
    has_many :participants, Participant
    has_many :game_results, GameResult
    has_many :snapshot_questions, GameSessionQuestion, preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  @doc "Every status the `game_session_status` database type accepts."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc "The statuses a room counts as live in, and which the partial indexes guard."
  @spec active_statuses() :: [atom()]
  def active_statuses, do: @active_statuses

  @doc """
  The statuses a room is over in, by any reason.

  `LiveQuiz.Games` guards its closing transition with this list, so a status
  that does not actually end a room cannot be written by the `UPDATE` that is
  supposed to end one.
  """
  @spec closed_statuses() :: [atom()]
  def closed_statuses, do: @closed_statuses

  @doc "How many characters a join code has."
  @spec join_code_length() :: pos_integer()
  def join_code_length, do: @join_code_length

  @doc """
  The 32 unambiguous symbols a join code is drawn from (AD-25).

  `O`/`0` and `I`/`1` are left out so a code read out loud cannot be mistyped.
  """
  @spec join_code_alphabet() :: String.t()
  def join_code_alphabet, do: @join_code_alphabet

  @doc "The durations a question may be given, in seconds (AD-38)."
  @spec question_durations() :: [pos_integer()]
  def question_durations, do: @question_durations

  @doc "Whether the room is still live — waiting for people or already running."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{status: status}), do: status in @active_statuses

  @doc """
  Whether the match has a question taking answers right now.

  A question is open while the match is running, a position has been advanced to
  and no closing instant was stamped. The status is part of the answer because a
  match that ended — finished, cancelled or expired — has no open question, even
  if it stopped with a position still set.
  """
  @spec question_open?(t()) :: boolean()
  def question_open?(%__MODULE__{status: :in_progress} = session) do
    not is_nil(session.current_question_position) and
      is_nil(session.current_question_closed_at)
  end

  def question_open?(%__MODULE__{}), do: false

  @doc """
  Whether the deadline written on the room has already passed.

  Only about the clock: a room with no deadline running answers `false`, and a
  question whose instant is behind us answers `true` whether or not anybody has
  closed it yet. Combining that with `question_open?/1` is what tells a caller
  there is something to close.

  It lives here because three callers ask it — the context before closing by
  timeout, the timer before firing and the supervisor before re-arming on boot
  — and a deadline they disagreed about would be a question closed twice or
  never.
  """
  @spec question_due?(t()) :: boolean()
  def question_due?(%__MODULE__{current_question_ends_at: nil}), do: false

  def question_due?(%__MODULE__{current_question_ends_at: ends_at}) do
    DateTime.compare(DateTime.utc_now(), ends_at) != :lt
  end

  @doc """
  The match as a running one, or why it is not.

  A guard rather than a predicate because every caller of it is a `with` whose
  next step needs the session: reading it back after a boolean would be a second
  chance for the status to have changed.
  """
  @spec ensure_running(t()) :: {:ok, t()} | {:error, :invalid_status}
  def ensure_running(%__MODULE__{status: :in_progress} = session), do: {:ok, session}
  def ensure_running(_over_or_gone), do: {:error, :invalid_status}

  @doc """
  Whether the question at `position` is done being answered.

  A question the match has already moved past is settled by definition; the one
  it is sitting on is settled only once it has been closed; one it has not
  reached yet is not settled at all. This is what keeps an answer key from
  leaking through a screen or an endpoint that asks too early (AD-46).
  """
  @spec ensure_question_settled(t(), pos_integer()) :: :ok | {:error, :question_open}
  def ensure_question_settled(%__MODULE__{current_question_position: nil}, _position),
    do: {:error, :question_open}

  def ensure_question_settled(%__MODULE__{current_question_position: current} = session, position) do
    cond do
      position < current -> :ok
      position > current -> {:error, :question_open}
      question_open?(session) -> {:error, :question_open}
      true -> :ok
    end
  end

  @doc """
  Casts and validates the attributes given when a room is opened.

  Neither `host_id` nor `quiz_id` is cast: both come from the caller scope and
  are assigned by the context, as is `join_code`, which is generated there
  (F2-02). The code is always persisted upcased.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(session, attrs) do
    session
    |> cast(attrs, [:quiz_title, :join_code, :question_duration_seconds])
    # Never cast: the durable identity of a room is issued by the server, and a
    # room whose id came from the request is a room somebody else could name.
    |> put_public_id()
    |> update_change(:quiz_title, &Changesets.trim/1)
    |> update_change(:join_code, &Changesets.upcase/1)
    |> validate_required([:quiz_title, :join_code, :host_id, :question_duration_seconds])
    |> validate_length(:quiz_title, min: 3, max: 120)
    |> validate_inclusion(:question_duration_seconds, @question_durations,
      message: "escolha uma das durações disponíveis"
    )
    |> check_constraint(:question_duration_seconds,
      name: :question_duration_allowed,
      message: "escolha uma das durações disponíveis"
    )
    |> validate_length(:join_code, is: @join_code_length)
    |> validate_format(:join_code, @join_code_regex,
      message: "deve usar apenas os caracteres #{@join_code_alphabet}"
    )
    |> assoc_constraint(:host)
    |> assoc_constraint(:quiz)
    |> unique_room_constraints()
  end

  @doc """
  Casts a change to how long each question of the match lasts.

  The duration is chosen when the room is opened (AD-38) and stops being
  negotiable the moment the match leaves `waiting`: a match already running
  promised everybody a single deadline per question (AD-39), and moving it
  halfway through would make the countdown people are watching a lie. A room
  that is over is refused for the same reason — there is nothing left to time.
  """
  @spec duration_changeset(t(), map()) :: Ecto.Changeset.t()
  def duration_changeset(session, attrs) do
    session
    |> cast(attrs, [:question_duration_seconds])
    |> validate_required([:question_duration_seconds])
    |> validate_inclusion(:question_duration_seconds, @question_durations,
      message: "escolha uma das durações disponíveis"
    )
    |> validate_duration_still_open()
    |> check_constraint(:question_duration_seconds,
      name: :question_duration_allowed,
      message: "escolha uma das durações disponíveis"
    )
  end

  @doc """
  Moves the room to another status, stamping the matching timestamp.

  Going live stamps `started_at`; closing the room, by any reason, stamps
  `finished_at` and drops any pending expiration. Pass `:at` to control the
  instant.

  The running application never moves a room through here: every transition it
  makes is a single `UPDATE` guarded by the status it is allowed to come from,
  because a read followed by a write would let two hosts both win. What this
  changeset is for is building a room already in a given state — which is what
  the fixtures do — without restating the timestamp rules that go with it.
  """
  @spec status_changeset(t(), atom(), keyword()) :: Ecto.Changeset.t()
  def status_changeset(session, status, opts \\ []) do
    at = opts |> Keyword.get(:at, DateTime.utc_now()) |> DateTime.truncate(:second)

    session
    |> cast(%{status: status}, [:status])
    |> validate_required([:status])
    |> stamp_status_timestamps(status, at)
    |> check_constraint(:started_at,
      name: :started_at_requires_status,
      message: "não pode ter início registrado enquanto a sala aguarda participantes"
    )
    |> unique_room_constraints()
  end

  @doc """
  Casts the host connection bookkeeping: who is holding the room and until when.

  `expires_at` lives here because the deadline is a consequence of the host
  being away (AD-23); the sweeper that acts on it arrives in F2-06.
  """
  @spec host_presence_changeset(t(), map()) :: Ecto.Changeset.t()
  def host_presence_changeset(session, attrs) do
    cast(session, attrs, [:host_connection_id, :host_disconnected_at, :expires_at])
  end

  # Only an actual change is refused: re-submitting the duration the room
  # already has is a no-op, not an attempt to move the goalposts.
  defp validate_duration_still_open(%Ecto.Changeset{} = changeset) do
    case {changeset.data.status, fetch_change(changeset, :question_duration_seconds)} do
      {:waiting, _change} ->
        changeset

      {_started, :error} ->
        changeset

      {_started, {:ok, _new_duration}} ->
        add_error(
          changeset,
          :question_duration_seconds,
          "não pode ser alterada depois que a partida começa"
        )
    end
  end

  defp stamp_status_timestamps(changeset, :in_progress, at) do
    case get_field(changeset, :started_at) do
      nil -> put_change(changeset, :started_at, at)
      _already_started -> changeset
    end
  end

  defp stamp_status_timestamps(changeset, status, at) when status in @closed_statuses do
    changeset
    |> put_change(:finished_at, at)
    |> put_change(:expires_at, nil)
  end

  defp stamp_status_timestamps(changeset, _status, _at), do: changeset

  # A room keeps the id it was born with. The join code is reusable once a room
  # is over — it is read out loud, so it is short — and that is what makes it a
  # fine way in and a poor way back: a durable address needs something that is
  # only ever about one room (R29).
  defp put_public_id(changeset) do
    case get_field(changeset, :public_id) do
      nil -> put_change(changeset, :public_id, Ecto.UUID.generate())
      _already_issued -> changeset
    end
  end

  defp unique_room_constraints(changeset) do
    changeset
    |> unique_constraint(:join_code,
      name: :game_sessions_active_join_code_index,
      message: "já existe uma sala ativa com este código"
    )
    |> unique_constraint(:host_id,
      name: :game_sessions_one_active_per_host_index,
      message: "você já possui uma sala ativa"
    )
  end
end
