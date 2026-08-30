defmodule LiveQuiz.Quizzes.AnswerOption do
  @moduledoc """
  One of the four answer options of a question.

  A partial unique index keeps a question from having two correct options;
  requiring that one of them *is* correct is a rule of the question transaction
  (F1-07), not of this schema.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias LiveQuiz.Quizzes.Question

  @type t :: %__MODULE__{}

  schema "answer_options" do
    field :text, :string
    field :position, :integer
    field :is_correct, :boolean, default: false

    belongs_to :question, Question

    timestamps(type: :utc_datetime)
  end

  @doc """
  Casts and validates a single answer option.
  """
  def changeset(answer_option, attrs) do
    answer_option
    |> cast(attrs, [:text, :position, :is_correct])
    |> validate_required([:text, :position, :is_correct])
    |> validate_length(:text, min: 1, max: 200)
    |> validate_inclusion(:position, 1..4)
    |> unique_constraint(:question_id,
      name: :answer_options_single_correct_index,
      message: "já existe uma alternativa correta"
    )
  end
end
