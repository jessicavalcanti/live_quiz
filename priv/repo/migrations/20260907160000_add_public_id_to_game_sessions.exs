defmodule LiveQuiz.Repo.Migrations.AddPublicIdToGameSessions do
  @moduledoc """
  Gives every room an identifier that is only ever about that room.

  The join code is short on purpose — it is read out loud — and it is reusable
  once a room is over, which is what makes it a fine way in and a poor way back.
  A link kept from a finished match resolves the code to whatever room holds it
  now: the same address answers about a different match, or answers 403 about
  one the reader has nothing to do with (R29).

  `public_id` is a UUID, unique and never reused. It is what durable addresses
  — a result, a history entry — are built from, while entry keeps the code.

  Rooms written before this migration are backfilled with fresh values, which
  is safe because nothing referred to them by this id yet.
  """

  use Ecto.Migration

  def up do
    alter table(:game_sessions) do
      add :public_id, :uuid
    end

    execute "UPDATE game_sessions SET public_id = gen_random_uuid() WHERE public_id IS NULL"

    alter table(:game_sessions) do
      modify :public_id, :uuid, null: false
    end

    create unique_index(:game_sessions, [:public_id])

    # Looking a room up by its code reads the most recent one, and the existing
    # unique index only covers the live ones. Without this, a lookup of a code
    # that has been through several rooms is a scan ordered by hand.
    create index(:game_sessions, [:join_code, "inserted_at DESC", "id DESC"],
             name: :game_sessions_join_code_recency_index
           )
  end

  def down do
    drop index(:game_sessions, [:join_code], name: :game_sessions_join_code_recency_index)
    drop unique_index(:game_sessions, [:public_id])

    alter table(:game_sessions) do
      remove :public_id
    end
  end
end
