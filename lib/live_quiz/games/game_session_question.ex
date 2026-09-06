defmodule LiveQuiz.Games.GameSessionQuestion do
  @moduledoc """
  A question of a quiz frozen into a match — one line of the snapshot.

  The match reads its content only from here, never from `LiveQuiz.Quizzes`
  (AD-36): a quiz is a living document, and reading it back during or after the
  game would let a later edit rewrite what was actually played.

  `question_id` points at the question this was copied from and is nullable on
  purpose, with `ON DELETE SET NULL`. Deleting the quiz erases the origin, not
  the record — the same reasoning that copied `quiz_title` into `game_sessions`
  in phase 2. The id is kept while it exists so phase 4 can relate matches of
  the same quiz.

  The parent id is not required here, so the snapshot of a whole match can be
  built as a nested changeset the way `LiveQuiz.Quizzes.Question` is; the
  `null: false` column is what refuses an orphan.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias LiveQuiz.Games.Answer
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.GameSessionAnswerOption
  alias LiveQuiz.Quizzes.Question

  @type t :: %__MODULE__{}

  @question_text_max_length 500

  schema "game_session_questions" do
    field :position, :integer
    field :question_text, :string
    field :scored_at, :utc_datetime_usec

    belongs_to :game_session, GameSession
    belongs_to :question, Question

    has_many :answer_options, GameSessionAnswerOption, preload_order: [asc: :position]
    has_many :answers, Answer

    timestamps(type: :utc_datetime)
  end

  @doc """
  Casts and validates the snapshot of one question.

  `question_text` copies the statement as it was, so it accepts anything the
  question of phase 1 accepts — up to #{@question_text_max_length} characters.
  `game_session_id` comes from the caller, either set on the struct or filled in
  by the association, and is never cast from outside.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(question, attrs) do
    question
    |> cast(attrs, [:position, :question_text, :question_id])
    |> update_change(:question_text, &trim/1)
    |> validate_required([:position, :question_text])
    |> validate_length(:question_text, min: 1, max: @question_text_max_length)
    |> validate_number(:position, greater_than: 0)
    |> assoc_constraint(:game_session)
    |> assoc_constraint(:question)
    |> unique_constraint([:game_session_id, :position],
      name: :game_session_questions_game_session_id_position_index,
      message: "já existe uma pergunta nesta posição"
    )
    |> check_constraint(:position,
      name: :position_positive,
      message: "deve ser maior que zero"
    )
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
