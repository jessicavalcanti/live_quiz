defmodule LiveQuiz.Accounts.RefreshToken do
  @moduledoc """
  One refresh token of one session, stored as a digest and grouped in a family.

  A family is a login. Refreshing spends the current row and writes the next one
  under the same `family_id`, so a session is a chain rather than a single
  long-lived secret — and the chain is what makes replay visible: a row spent
  twice means two holders, and only one of them is the person who logged in.

  The token itself is never stored. What is stored is its SHA-256, which is
  enough to recognise a token somebody presents and not enough to present one.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias LiveQuiz.Accounts.User

  @type t :: %__MODULE__{}

  schema "refresh_tokens" do
    field :family_id, Ecto.UUID
    field :token_hash, :binary
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc "Casts a row for a token that has just been issued."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(refresh_token, attrs) do
    refresh_token
    |> cast(attrs, [:user_id, :family_id, :token_hash, :expires_at])
    |> validate_required([:user_id, :family_id, :token_hash, :expires_at])
    |> unique_constraint(:token_hash)
    |> assoc_constraint(:user)
  end

  @doc """
  The digest a token is recognised by.

  SHA-256 of the token as it was handed out. Same input, same digest, and no
  way back — which is the whole reason the column holds this and not the token.
  """
  @spec hash(String.t()) :: binary()
  def hash(token) when is_binary(token), do: :crypto.hash(:sha256, token)

  @doc "Whether this row may still be spent."
  @spec spendable?(t(), DateTime.t()) :: boolean()
  def spendable?(%__MODULE__{} = token, now) do
    is_nil(token.used_at) and is_nil(token.revoked_at) and
      DateTime.compare(now, token.expires_at) == :lt
  end
end
