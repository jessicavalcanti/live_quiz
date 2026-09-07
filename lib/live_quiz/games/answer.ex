defmodule LiveQuiz.Games.Answer do
  @moduledoc """
  The alternative a participant chose for one question of a match.

  There is at most one line per participant per question (AD-41): changing the
  choice while the question is open rewrites `game_session_answer_option_id` and
  `answered_at` instead of adding a row, so the last pick is the one that
  counts. Not answering leaves no row at all — "no answer" is a difference, not
  a record (AD-43).

  `answered_at` is `utc_datetime_usec` because the speed bonus of phase 4
  measures the distance from the question opening to the answer, and whole
  seconds would tie half the room. It is always stamped by the server.

  `response_time_ms` is the distance from the question opening to
  `answered_at`, stamped once when the question is scored. It is stored instead
  of derived because the immutable result of AD-55 is built at the end of the
  match, when the opening instant of each question is long gone.

  `game_session_id` is redundant — the question already knows its match — and
  kept anyway: every query of phase 4 is by match, and the direct cascade keeps
  deletion simple.

  This schema does not check that the question, the option and the participant
  belong to the same match. That coherence is the context's job when it records
  an answer (F3-04).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.GameSessionAnswerOption
  alias LiveQuiz.Games.GameSessionQuestion
  alias LiveQuiz.Games.Participant

  @type t :: %__MODULE__{}

  schema "answers" do
    field :answered_at, :utc_datetime_usec
    field :response_time_ms, :integer, default: 0

    belongs_to :game_session, GameSession
    belongs_to :game_session_question, GameSessionQuestion
    belongs_to :participant, Participant
    belongs_to :game_session_answer_option, GameSessionAnswerOption

    timestamps(type: :utc_datetime)
  end

  @doc """
  Casts and validates one answer.

  All four references are required: an answer without a match, a question, a
  person or an alternative is not an answer. `answered_at` is required too and
  belongs to the server — a client-sent instant never reaches here, because the
  context is the one that builds these attributes.

  The uniqueness by (participant, question) is translated into "você já
  respondeu esta pergunta". The real write uses an upsert (AD-41), so this
  message is the last resort, not the usual path.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(answer, attrs) do
    answer
    |> cast(attrs, [
      :game_session_id,
      :game_session_question_id,
      :participant_id,
      :game_session_answer_option_id,
      :answered_at
    ])
    |> validate_required([
      :game_session_id,
      :game_session_question_id,
      :participant_id,
      :game_session_answer_option_id,
      :answered_at
    ])
    |> assoc_constraint(:game_session)
    |> assoc_constraint(:game_session_question)
    |> assoc_constraint(:participant)
    |> assoc_constraint(:game_session_answer_option)
    # The composite keys the database holds: an answer whose question,
    # participant and option each exist but belong to different rooms is not an
    # answer to anything. They fire before the single-column ones, so they are
    # named here for the error to reach the caller as a changeset (R35).
    |> foreign_key_constraint(:game_session_question_id,
      name: :answers_question_belongs_to_session,
      message: "não pertence a esta partida"
    )
    |> foreign_key_constraint(:participant_id,
      name: :answers_participant_belongs_to_session,
      message: "não pertence a esta partida"
    )
    |> foreign_key_constraint(:game_session_answer_option_id,
      name: :answers_option_belongs_to_question,
      message: "não pertence a esta pergunta"
    )
    |> unique_constraint([:participant_id, :game_session_question_id],
      name: :answers_participant_id_game_session_question_id_index,
      message: "você já respondeu esta pergunta"
    )
  end
end
