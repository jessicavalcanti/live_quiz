defmodule LiveQuiz.Repo.Migrations.AddResponseTimeToAnswers do
  use Ecto.Migration

  def change do
    alter table(:answers) do
      add :response_time_ms, :integer, null: false, default: 0
    end
  end
end
