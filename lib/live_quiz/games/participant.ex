defmodule LiveQuiz.Games.Participant do
  @moduledoc """
  Someone taking part in a room, with or without an account.

  The nickname is stored exactly as typed and compared through
  `nickname_normalized`, a persisted column derived from it (AD-26), so the
  database can guarantee case-insensitive uniqueness inside a room while the
  lobby still shows the spelling the person chose.

  Accents and inner spaces are *not* normalized on purpose: "Ana" and "Aná" are
  different nicknames, and so are "Ana Paula" and "Ana  Paula". This is a known
  limit, not a pending decision.

  The credential is a 32-byte opaque token that never touches the database in
  clear: only its SHA-256 digest is persisted in `access_token_hash` (AD-24).
  Generating it belongs to the context (F2-03); this schema only refuses a
  digest of the wrong size.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias LiveQuiz.Accounts.User
  alias LiveQuiz.Games.GameSession

  @type t :: %__MODULE__{}

  @nickname_min_length 2
  @nickname_max_length 20
  @nickname_regex ~r/^[\p{L}\p{N} _-]+$/u
  @access_token_hash_size 32

  schema "participants" do
    field :nickname, :string
    field :nickname_normalized, :string
    field :access_token_hash, :binary
    field :connection_id, Ecto.UUID
    field :joined_at, :utc_datetime
    field :left_at, :utc_datetime
    field :released_at, :utc_datetime

    # Filled in by the Presence (F2-06), never read from the database.
    field :connected, :boolean, virtual: true, default: false

    belongs_to :game_session, GameSession
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc "The shortest nickname accepted, in characters."
  @spec nickname_min_length() :: pos_integer()
  def nickname_min_length, do: @nickname_min_length

  @doc "The longest nickname accepted, in characters."
  @spec nickname_max_length() :: pos_integer()
  def nickname_max_length, do: @nickname_max_length

  @doc "How many bytes the persisted access token digest has."
  @spec access_token_hash_size() :: pos_integer()
  def access_token_hash_size, do: @access_token_hash_size

  @doc """
  Normalizes a nickname for comparison: trims the ends and downcases.

      iex> LiveQuiz.Games.Participant.normalize_nickname(" Ana ")
      "ana"

  """
  @spec normalize_nickname(String.t()) :: String.t()
  def normalize_nickname(nickname) when is_binary(nickname) do
    nickname |> String.trim() |> String.downcase()
  end

  @doc """
  Applies the nickname rules to any changeset carrying a `:nickname` change.

  It lives apart from `join_changeset/2` because the join screen validates the
  nickname while it is being typed, long before there is a room, a seat or a
  credential to build a participation with. Both paths go through here, so the
  rules and their messages have a single home.
  """
  @spec validate_nickname(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_nickname(changeset) do
    changeset
    |> update_change(:nickname, &trim/1)
    |> validate_required([:nickname])
    |> validate_length(:nickname, min: @nickname_min_length, max: @nickname_max_length)
    |> validate_format(:nickname, @nickname_regex,
      message: "use apenas letras, números, espaços, hífen e sublinhado"
    )
  end

  @doc """
  Casts and validates what someone types when joining a room.

  Only the nickname comes from outside. `game_session_id`, `user_id`,
  `access_token_hash` and `joined_at` are set by the context when building the
  struct, and `nickname_normalized` is always derived here — a value sent in
  `attrs` is ignored.
  """
  @spec join_changeset(t(), map()) :: Ecto.Changeset.t()
  def join_changeset(participant, attrs) do
    participant
    |> cast(attrs, [:nickname])
    |> validate_nickname()
    |> validate_required([:game_session_id, :access_token_hash, :joined_at])
    |> put_nickname_normalized()
    |> validate_access_token_hash()
    |> assoc_constraint(:game_session)
    |> assoc_constraint(:user)
    |> unique_constraint(:nickname,
      name: :participants_game_session_id_nickname_normalized_index,
      message: "este apelido já está em uso nesta sala"
    )
    |> unique_constraint(:user_id,
      name: :participants_one_active_per_user_index,
      message: "você já está participando de outra sala"
    )
    |> unique_constraint(:access_token_hash)
    |> check_constraint(:nickname,
      name: :nickname_length,
      message: "deve ter entre #{@nickname_min_length} e #{@nickname_max_length} caracteres"
    )
  end

  @doc """
  Casts the connection bookkeeping of a participation.

  `connection_id` holds the single live connection (AD-30), `left_at` marks a
  voluntary exit — which never gives the seat back (AD-27) — and `released_at`
  frees the account to join another room.
  """
  @spec connection_changeset(t(), map()) :: Ecto.Changeset.t()
  def connection_changeset(participant, attrs) do
    participant
    |> cast(attrs, [:connection_id, :left_at, :released_at])
    |> unique_constraint(:user_id,
      name: :participants_one_active_per_user_index,
      message: "você já está participando de outra sala"
    )
  end

  @doc """
  Replaces the persisted digest of the access token.

  A participation holds a single credential (AD-30), so handing a new token to
  whoever comes back retires the previous one by construction. The clear token
  is generated by the context and never reaches this changeset.
  """
  @spec credential_changeset(t(), binary()) :: Ecto.Changeset.t()
  def credential_changeset(participant, access_token_hash) do
    participant
    |> change(access_token_hash: access_token_hash)
    |> validate_access_token_hash()
    |> unique_constraint(:access_token_hash)
  end

  @doc """
  Tells whether the participation still shows up in the lobby list.

  Someone who left or was released keeps the row — it is the seat and the
  history — but is no longer listed.
  """
  @spec in_lobby?(t()) :: boolean()
  def in_lobby?(%__MODULE__{left_at: left_at, released_at: released_at}) do
    is_nil(left_at) and is_nil(released_at)
  end

  defp put_nickname_normalized(changeset) do
    case get_field(changeset, :nickname) do
      nil -> changeset
      nickname -> put_change(changeset, :nickname_normalized, normalize_nickname(nickname))
    end
  end

  defp validate_access_token_hash(changeset) do
    case get_field(changeset, :access_token_hash) do
      nil ->
        changeset

      hash when is_binary(hash) and byte_size(hash) == @access_token_hash_size ->
        changeset

      _wrong_size ->
        add_error(
          changeset,
          :access_token_hash,
          "deve ter exatamente #{@access_token_hash_size} bytes"
        )
    end
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
