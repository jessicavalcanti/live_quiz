defmodule LiveQuiz.Repo.Migrations.AddScoredAtToGameSessionQuestions do
  use Ecto.Migration

  def change do
    alter table(:game_session_questions) do
      add :scored_at, :utc_datetime_usec
    end
  end
end
