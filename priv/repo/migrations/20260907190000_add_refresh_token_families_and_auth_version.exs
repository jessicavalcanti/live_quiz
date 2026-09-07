defmodule LiveQuiz.Repo.Migrations.AddRefreshTokenFamiliesAndAuthVersion do
  @moduledoc """
  What it takes to end a session that lives in a signed token.

  A JWT proves itself: the server verifies a signature and asks the database
  nothing. That is what makes it cheap, and it is also why logging out did
  nothing — a refresh token stayed valid for its thirty days no matter what,
  and a password reset that ended every web session left every API session
  untouched (R03).

  Two mechanisms, because there are two questions.

  **This device, right now.** `refresh_tokens` stores the hash of each refresh
  token — never the token — grouped into a *family*: one family per login, one
  row per rotation. Refreshing spends a row and issues the next one in the same
  family. A row spent twice means the token was replayed, and the answer is to
  revoke the whole family: whichever of the two holders is the thief, neither
  keeps the session.

  **Every device, at once.** `users.auth_version` is compared against a claim
  the access token carries. Incrementing it rejects every access token already
  issued, immediately, without a lookup per request — the account row is
  already read to resolve the subject, so the comparison is free.
  """

  use Ecto.Migration

  def change do
    alter table(:users) do
      add :auth_version, :integer, null: false, default: 0
    end

    create table(:refresh_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # One per login. Rotation keeps it; reuse revokes everything under it.
      add :family_id, :uuid, null: false
      # The digest, never the token: whoever reads this table cannot use it.
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:refresh_tokens, [:token_hash])
    create index(:refresh_tokens, [:user_id])
    create index(:refresh_tokens, [:family_id])
    # The sweep of what has expired reads this and nothing else.
    create index(:refresh_tokens, [:expires_at])
  end
end
