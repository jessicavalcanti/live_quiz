defmodule LiveQuiz.Quizzes.Question do
  @moduledoc """
  A question inside a quiz, positioned from 1 to n and answered by one of its
  four answer options.

  A question is a transactional unit: it is either born complete and valid or it
  is not born at all. The set rules below — exactly four options, exactly one
  correct, no repeated texts — are checked on the parent changeset, and the
  partial unique index in the database is the last line of defence behind them.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias LiveQuiz.Quizzes.AnswerOption
  alias LiveQuiz.Quizzes.Quiz

  @type t :: %__MODULE__{}

  @options_per_question 4

  @doc "How many answer options every question must have."
  @spec options_per_question() :: pos_integer()
  def options_per_question, do: @options_per_question

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
    |> update_change(:text, &trim/1)
    |> validate_required([:text, :position])
    |> validate_length(:text, min: 3, max: 500)
    |> validate_number(:position, greater_than: 0)
    |> cast_assoc(:answer_options, required: true, with: &AnswerOption.changeset/2)
    |> validate_answer_options()
    |> unique_constraint([:quiz_id, :position], name: :questions_quiz_id_position_key)
  end

  # Only runs when the options were actually cast. Leaving the stored options
  # untouched — editing just the question text — cannot break rules that were
  # already satisfied when they were written.
  defp validate_answer_options(changeset) do
    case Map.fetch(changeset.changes, :answer_options) do
      :error ->
        changeset

      {:ok, option_changesets} ->
        options = Enum.map(option_changesets, &apply_changes/1)

        changeset
        |> validate_options_count(options)
        |> validate_single_correct_option(options)
        |> validate_distinct_option_texts(options)
    end
  end

  defp validate_options_count(changeset, options)
       when length(options) == @options_per_question,
       do: changeset

  defp validate_options_count(changeset, _options) do
    add_error(
      changeset,
      :answer_options,
      "a pergunta deve ter exatamente #{@options_per_question} alternativas"
    )
  end

  defp validate_single_correct_option(changeset, options) do
    case Enum.count(options, & &1.is_correct) do
      1 -> changeset
      0 -> add_error(changeset, :answer_options, "marque a alternativa correta")
      _many -> add_error(changeset, :answer_options, "marque apenas uma alternativa correta")
    end
  end

  defp validate_distinct_option_texts(changeset, options) do
    comparable =
      options
      |> Enum.map(& &1.text)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

    if length(comparable) == length(Enum.uniq(comparable)) do
      changeset
    else
      add_error(changeset, :answer_options, "as alternativas não podem ter textos repetidos")
    end
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
