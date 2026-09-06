defmodule LiveQuiz.Games.GameResult do
  @moduledoc """
  Immutable snapshot of one participant's final result in a game session.

  The references are retained for lookup and authorization. The copied text and
  metrics are the historical source of truth, so callers should only insert
  this schema once.
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
