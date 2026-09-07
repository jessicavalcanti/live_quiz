defmodule LiveQuiz.Games.GameResult do
  @moduledoc """
  Immutable snapshot of one participant's final result in a game session.

  The references are retained for lookup and authorization. The copied text and
  metrics are the historical source of truth, so callers should only insert
  this schema once.

  `quiz_id` and `user_id` are nullified when what they point at is deleted:
  the result outlives the quiz, which is why the title and the statements were
  copied into it. `game_session_id` and `participant_id` cascade instead, so a
  result does not outlive the match or the participation it belongs to. See
  `LiveQuiz.Games.History` for what that means for retention.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias LiveQuiz.Accounts.User
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Quizzes.Quiz

  @type t :: %__MODULE__{}

  schema "game_results" do
    field :quiz_title, :string
    field :nickname, :string
    field :score, :integer
    field :correct_answers, :integer
    field :incorrect_answers, :integer
    field :unanswered_questions, :integer
    field :answered_questions, :integer
    field :played_questions, :integer
    field :total_questions, :integer
    field :total_response_time_ms, :integer
    field :average_response_time_ms, :integer
    field :final_position, :integer
    field :question_results, :map, default: %{}

    belongs_to :game_session, GameSession
    belongs_to :participant, Participant
    belongs_to :user, User
    belongs_to :quiz, Quiz

    timestamps(type: :utc_datetime)
  end

  @doc "Casts and validates the complete final snapshot before insertion."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(result, attrs) do
    result
    |> cast(attrs, [
      :game_session_id,
      :participant_id,
      :user_id,
      :quiz_id,
      :quiz_title,
      :nickname,
      :score,
      :correct_answers,
      :incorrect_answers,
      :unanswered_questions,
      :answered_questions,
      :played_questions,
      :total_questions,
      :total_response_time_ms,
      :average_response_time_ms,
      :final_position,
      :question_results
    ])
    |> validate_required([
      :game_session_id,
      :participant_id,
      :quiz_title,
      :nickname,
      :score,
      :correct_answers,
      :incorrect_answers,
      :unanswered_questions,
      :answered_questions,
      :played_questions,
      :total_questions,
      :total_response_time_ms,
      :average_response_time_ms,
      :final_position,
      :question_results
    ])
    |> validate_number(:score, greater_than_or_equal_to: 0)
    |> validate_number(:correct_answers, greater_than_or_equal_to: 0)
    |> validate_number(:incorrect_answers, greater_than_or_equal_to: 0)
    |> validate_number(:unanswered_questions, greater_than_or_equal_to: 0)
    |> validate_number(:answered_questions, greater_than_or_equal_to: 0)
    |> validate_number(:played_questions, greater_than_or_equal_to: 0)
    |> validate_number(:total_questions, greater_than_or_equal_to: 0)
    |> validate_questions_add_up()
    |> validate_number(:total_response_time_ms, greater_than_or_equal_to: 0)
    |> validate_number(:average_response_time_ms, greater_than_or_equal_to: 0)
    |> validate_number(:final_position, greater_than: 0)
    |> validate_length(:quiz_title, min: 1, max: 120)
    |> validate_length(:nickname, min: 1, max: 20)
    |> validate_question_results()
    |> assoc_constraint(:game_session)
    |> assoc_constraint(:participant)
    |> assoc_constraint(:user)
    |> assoc_constraint(:quiz)
    |> unique_constraint([:game_session_id, :participant_id],
      name: :game_results_game_session_id_participant_id_index,
      message: "este participante já possui resultado nesta partida"
    )
  end

  # Every question the match applied ends up in exactly one of the two buckets.
  # A result where they do not add up is a result whose numbers were counted
  # over different populations, which is how absences for questions nobody was
  # ever shown got in.
  defp validate_questions_add_up(changeset) do
    answered = get_field(changeset, :answered_questions)
    unanswered = get_field(changeset, :unanswered_questions)
    played = get_field(changeset, :played_questions)
    total = get_field(changeset, :total_questions)

    changeset
    |> check_sum(answered, unanswered, played)
    |> check_coverage(played, total)
  end

  defp check_sum(changeset, answered, unanswered, played)
       when is_integer(answered) and is_integer(unanswered) and is_integer(played) do
    if answered + unanswered == played do
      changeset
    else
      add_error(
        changeset,
        :played_questions,
        "deve ser a soma das respondidas com as não respondidas"
      )
    end
  end

  defp check_sum(changeset, _answered, _unanswered, _played), do: changeset

  defp check_coverage(changeset, played, total)
       when is_integer(played) and is_integer(total) and played > total do
    add_error(changeset, :total_questions, "não pode ser menor que as perguntas aplicadas")
  end

  defp check_coverage(changeset, _played, _total), do: changeset

  defp validate_question_results(changeset) do
    validate_change(changeset, :question_results, fn :question_results, value ->
      if is_map(value) do
        []
      else
        [question_results: "deve ser um objeto ou uma lista JSON válida"]
      end
    end)
  end
end
