defmodule LiveQuiz.Games.GameSessionAnswerOption do
  @moduledoc """
  One alternative of a snapshot question, with the frozen answer key.

  `is_correct` here is *the* source of truth about what was right, during the
  match and forever after (AD-36). Nothing in the execution asks the quiz.

  Unlike `LiveQuiz.Quizzes.AnswerOption`, no rule of the set — exactly four
  options, exactly one correct — is checked here. The snapshot copies a question
  that was already valid when it was written; re-validating the set would only
  create a way for a legitimate copy to be refused.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias LiveQuiz.Games.GameSessionQuestion
  alias LiveQuiz.Quizzes.AnswerOption

  @type t :: %__MODULE__{}

  @text_max_length 200

  schema "game_session_answer_options" do
    field :text, :string
    field :position, :integer
    field :is_correct, :boolean, default: false

    # Filled in by the context when the question is tallied (F3-06), never read
    # from the database.
    field :answers_count, :integer, virtual: true

    belongs_to :game_session_question, GameSessionQuestion
    belongs_to :original_answer_option, AnswerOption

    timestamps(type: :utc_datetime)
  end

  @doc """
  Casts and validates the snapshot of one answer option.

  The limits mirror phase 1: text of 1 to #{@text_max_length} characters and a
  positive position. `game_session_question_id` is not cast — it comes from the
  struct or from the parent association.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(answer_option, attrs) do
    answer_option
    |> cast(attrs, [:text, :position, :is_correct, :original_answer_option_id])
    |> update_change(:text, &trim/1)
    |> validate_required([:text, :position, :is_correct])
    |> validate_length(:text, min: 1, max: @text_max_length)
    |> validate_number(:position, greater_than: 0)
    |> assoc_constraint(:game_session_question)
    |> assoc_constraint(:original_answer_option)
    |> unique_constraint([:game_session_question_id, :position],
      name: :game_session_answer_options_position_index,
      message: "já existe uma alternativa nesta posição"
    )
    |> check_constraint(:position,
      name: :position_positive,
      message: "deve ser maior que zero"
    )
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
