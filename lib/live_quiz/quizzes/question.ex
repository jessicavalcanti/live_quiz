defmodule LiveQuiz.Quizzes.Question do
  @moduledoc """
  A question inside a quiz, positioned from 1 to n and answered by one of its
  four answer options.

  This is the base changeset: it validates the question's own fields and casts
  the nested options. The set-level rules (exactly four options, exactly one
  correct, no duplicated texts) belong to F1-07 and are added there.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias LiveQuiz.Quizzes.AnswerOption
  alias LiveQuiz.Quizzes.Quiz

  @type t :: %__MODULE__{}

  schema "questions" do
    field :text, :string
    field :position, :integer

    belongs_to :quiz, Quiz
    has_many :answer_options, AnswerOption, preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  @doc """
  Casts and validates a question along with its answer options.
  """
  def changeset(question, attrs) do
    question
    |> cast(attrs, [:text, :position])
    |> validate_required([:text, :position])
    |> validate_length(:text, min: 3, max: 500)
    |> validate_number(:position, greater_than: 0)
    |> cast_assoc(:answer_options, required: true, with: &AnswerOption.changeset/2)
    |> unique_constraint([:quiz_id, :position], name: :questions_quiz_id_position_key)
  end
end
