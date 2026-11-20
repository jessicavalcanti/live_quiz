defmodule LiveQuiz.Repo.Migrations.EnforceHistoryRetention do
  use Ecto.Migration

  def up do
    drop constraint(:game_sessions, :game_sessions_host_id_fkey)

    alter table(:game_sessions) do
      modify :host_id, references(:users, on_delete: :nilify_all), null: true
    end

    create constraint(:game_sessions, :active_session_requires_host,
             check: "host_id IS NOT NULL OR status NOT IN ('waiting', 'in_progress')"
           )

    drop constraint(:participants, :participants_user_id_fkey)

    alter table(:participants) do
      modify :user_id, references(:users, on_delete: :delete_all)
    end

    drop constraint(:game_results, :game_results_user_id_fkey)

    alter table(:game_results) do
      modify :user_id, references(:users, on_delete: :delete_all)
    end
  end

  def down do
    raise "History retention cannot be rolled back after account deletion; restore a backup instead"
  end
end
