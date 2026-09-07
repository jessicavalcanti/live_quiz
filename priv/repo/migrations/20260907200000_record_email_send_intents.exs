defmodule LiveQuiz.Repo.Migrations.RecordEmailSendIntents do
  @moduledoc """
  What it takes for "we sent it" to be true.

  Three of this application's flows write a token to the database and then talk
  to an SMTP server while somebody waits: confirming an account, changing an
  address, resetting a password. The token was durable and the send was not, so
  a provider that was slow made the interface slow, and a provider that was
  down made the interface *lie* — the caller discarded the failure and the
  screen said the message was on its way (R07).

  The intent is what becomes durable here. Writing it happens in the same
  transaction as the token, so the two facts cannot disagree, and a courier
  process drains the table afterwards with a bounded number of attempts.

  ## About the body

  The row holds the rendered message, link included, which is a live secret at
  rest for as long as the message is undelivered. That window is deliberately
  the *shortest* one in the whole flow: the row is deleted the moment it is
  sent, and dropped when the token behind it expires — while the same link sits
  in somebody's inbox for days. What it buys is a retry that does not have to
  mint a second token, which is the thing that would really multiply live
  secrets.
  """

  use Ecto.Migration

  def change do
    create table(:email_deliveries) do
      # Nullable on purpose: an intent outlives the account it was written for
      # only long enough to stop, and deleting a user must not fail on this.
      add :user_id, references(:users, on_delete: :delete_all)
      add :recipient, :string, null: false
      add :subject, :string, null: false
      add :body, :text, null: false
      # Which flow wrote it, for telemetry and for reading the table by eye.
      add :kind, :string, null: false
      # The idempotency key. One intent per token, so a retry of the *caller*
      # does not become a second message.
      add :dedupe_key, :string, null: false
      add :attempts, :integer, null: false, default: 0
      # When it becomes eligible again. Backoff writes into this column rather
      # than into a process that a restart would forget.
      add :deliver_after, :utc_datetime, null: false
      # Past this, sending would deliver a dead link, so it is not sent at all.
      add :expires_at, :utc_datetime, null: false
      add :last_error, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:email_deliveries, [:dedupe_key])
    # The claim query reads exactly this: what is due, oldest first.
    create index(:email_deliveries, [:deliver_after])
  end
end
