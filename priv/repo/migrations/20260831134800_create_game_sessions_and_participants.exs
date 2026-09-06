defmodule LiveQuiz.Repo.Migrations.CreateGameSessionsAndParticipants do
  use Ecto.Migration

  @moduledoc """
  Foundation of the game session domain: the room and the people inside it.

  The rules that several connections dispute at the same time — a unique code
  among live rooms, one live room per host, one nickname per room and one open
  participation per account — are carried by partial unique indexes, so the
  database is the arbiter instead of in-memory validation.
  """

  def change do
    execute(
      "CREATE TYPE game_session_status AS ENUM ('waiting','in_progress','finished','cancelled','expired')",
      "DROP TYPE game_session_status"
    )

    create table(:game_sessions) do
      add :quiz_id, references(:quizzes, on_delete: :nilify_all)
      add :host_id, references(:users, on_delete: :delete_all), null: false
      add :quiz_title, :string, size: 120, null: false
      add :join_code, :string, size: 6, null: false
      add :status, :game_session_status, null: false, default: "waiting"
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime
      add :host_connection_id, :uuid
      add :host_disconnected_at, :utc_datetime
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:game_sessions, [:join_code],
             where: "status IN ('waiting','in_progress')",
             name: :game_sessions_active_join_code_index
           )

    create unique_index(:game_sessions, [:host_id],
             where: "status IN ('waiting','in_progress')",
             name: :game_sessions_one_active_per_host_index
           )

    create index(:game_sessions, [:quiz_id])
    create index(:game_sessions, [:expires_at], where: "expires_at IS NOT NULL")

    create constraint(:game_sessions, :join_code_format,
             check: "join_code ~ '^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{6}$'"
           )

    create constraint(:game_sessions, :started_at_requires_status,
             check: "started_at IS NULL OR status <> 'waiting'"
           )

    # `user_id` nullifies instead of cascading: deleting the account must not
    # erase the participation record that phase 4 reads back as room history.
    create table(:participants) do
      add :game_session_id, references(:game_sessions, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :nickname, :string, size: 20, null: false
      add :nickname_normalized, :string, size: 20, null: false
      add :access_token_hash, :binary, null: false
      add :connection_id, :uuid
      add :joined_at, :utc_datetime, null: false
      add :left_at, :utc_datetime
      add :released_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:participants, [:game_session_id, :nickname_normalized])
    create unique_index(:participants, [:access_token_hash])
    create index(:participants, [:game_session_id])
    create index(:participants, [:user_id])

    create unique_index(:participants, [:user_id],
             where: "released_at IS NULL AND user_id IS NOT NULL",
             name: :participants_one_active_per_user_index
           )

    create constraint(:participants, :nickname_length,
             check: "char_length(nickname) BETWEEN 2 AND 20"
           )
  end
end
