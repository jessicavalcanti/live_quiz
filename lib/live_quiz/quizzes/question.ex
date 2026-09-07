defmodule LiveQuiz.Quizzes.Question do
  @moduledoc """
  A question inside a quiz, positioned from 1 to n and answered by one of its
  four answer options.

  A question is a transactional unit: it is either born complete and valid or it
  is not born at all. The set rules below — exactly four options, occupying
  positions 1 to 4 with no repeats, exactly one correct, no repeated texts —
  are checked on the parent changeset, and the partial unique index in the
  database is the last line of defence behind them.

  The rules are about the *set*, which is why they live here and not on
  `LiveQuiz.Quizzes.AnswerOption`: an option numbered 3 is valid on its own and
  says nothing about whether another option is also numbered 3.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias LiveQuiz.Changesets
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
    |> update_change(:text, &Changesets.trim/1)
    |> validate_required([:text, :position])
    |> validate_length(:text, min: 3, max: 500)
    |> validate_number(:position, greater_than: 0)
    |> cast_assoc(:answer_options,
      required: true,
      with: &AnswerOption.changeset/2,
      # A payload that leaves out an option the question already has is a
      # payload that does not describe the set it claims to. The default policy
      # would silently drop the missing rows; refusing is what turns a malformed
      # edit into a validation error instead of a quiet deletion (R31).
      on_replace: :mark_as_invalid
    )
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
        |> validate_option_positions(options)
        |> validate_single_correct_option(options)
        |> validate_distinct_option_texts(options)
    end
  end

  # Four options, each numbered 1 to 4, is not the same rule as "the positions
  # are 1, 2, 3 and 4". `[1, 1, 3, 4]` satisfies the first and not the second,
  # and it used to reach the deferred unique index and fail at commit — a
  # database error where the caller should have been told which field is wrong
  # (R31).
  # Only once the count is right. "You sent three options" already says what is
  # wrong with three options; adding "and they do not occupy 1 to 4" is the same
  # complaint twice.
  defp validate_option_positions(changeset, options)
       when length(options) != @options_per_question,
       do: changeset

  defp validate_option_positions(changeset, options) do
    positions = options |> Enum.map(& &1.position) |> Enum.reject(&is_nil/1)

    if Enum.sort(positions) == Enum.to_list(1..@options_per_question) do
      changeset
    else
      add_error(
        changeset,
        :answer_options,
        "as alternativas devem ocupar as posições de 1 a #{@options_per_question}, sem repetir"
      )
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
end
