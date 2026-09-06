defmodule LiveQuiz.Repo.Migrations.AddScoringMetricsAndGameResults do
  use Ecto.Migration

  def change do
    alter table(:participants) do
      add :score, :integer, null: false, default: 0
      add :correct_answers, :integer, null: false, default: 0
      add :incorrect_answers, :integer, null: false, default: 0
      add :total_response_time_ms, :integer, null: false, default: 0
      add :final_position, :integer
    end

    create table(:game_results) do
      add :game_session_id, references(:game_sessions, on_delete: :delete_all), null: false
      add :participant_id, references(:participants, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :quiz_id, references(:quizzes, on_delete: :nilify_all)
      add :quiz_title, :string, size: 120, null: false
      add :nickname, :string, size: 20, null: false
      add :score, :integer, null: false
      add :correct_answers, :integer, null: false
      add :incorrect_answers, :integer, null: false
      add :unanswered_questions, :integer, null: false
      add :answered_questions, :integer, null: false
      add :total_response_time_ms, :integer, null: false
      add :average_response_time_ms, :integer, null: false
      add :final_position, :integer, null: false
      add :question_results, :jsonb, null: false, default: fragment("'[]'::jsonb")

      timestamps(type: :utc_datetime)
    end

    create unique_index(:game_results, [:game_session_id, :participant_id])
    create index(:game_results, [:participant_id])
    create index(:game_results, [:user_id])
    create index(:game_results, [:quiz_id])
  end
end
