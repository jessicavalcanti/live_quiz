defmodule LiveQuiz.Mail.Delivery do
  @moduledoc """
  One message this application intends to send, written down before it is sent.

  A row exists while the message is owed. It is deleted once delivered, and
  dropped when the token it carries expires — so the table holds what is
  pending and never a log of what happened, which is also what keeps a rendered
  reset link from living in the database any longer than the send does (R07).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias LiveQuiz.Accounts.User

  @type t :: %__MODULE__{}

  schema "email_deliveries" do
    field :recipient, :string
    field :subject, :string
    field :body, :string
    field :kind, :string
    field :dedupe_key, :string
    field :attempts, :integer, default: 0
    field :deliver_after, :utc_datetime
    field :expires_at, :utc_datetime
    field :last_error, :string

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @required [:recipient, :subject, :body, :kind, :dedupe_key, :deliver_after, :expires_at]

  @doc "Casts an intent to send."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [:user_id | @required])
    |> validate_required(@required)
    |> unique_constraint(:dedupe_key)
    |> assoc_constraint(:user)
  end
end
