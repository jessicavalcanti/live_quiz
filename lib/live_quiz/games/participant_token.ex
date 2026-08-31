defmodule LiveQuiz.Games.ParticipantToken do
  @moduledoc """
  The credential that identifies one participation, with or without an account.

  It is an opaque 32-byte token (AD-24), not a JWT: it has to live as long as
  the room, be revocable at any moment and mean the same thing on the web and
  on the API, none of which asks for claims or a refresh policy. It carries no
  expiration of its own either — a token dies with the room it belongs to,
  because a room that is over stops answering, not because a clock ran out.

  Only the SHA-256 digest of the token reaches the database, in
  `participants.access_token_hash`. The clear value exists once, in the answer
  of `LiveQuiz.Games.join_game_session/4`, and is never persisted nor logged.
  Since the digest is deterministic, looking a participation up stays a plain
  equality search on an indexed column.

  The clear form is Base64 URL-safe without padding, so it travels unescaped in
  a cookie, a header or a query string.
  """

  @rand_size 32
  @hash_algorithm :sha256

  @doc """
  Generates `{clear_token, digest}`. The clear token is never persisted.

      iex> {token, hash} = LiveQuiz.Games.ParticipantToken.build()
      iex> LiveQuiz.Games.ParticipantToken.hash(token) == {:ok, hash}
      true

  """
  @spec build() :: {String.t(), binary()}
  def build do
    bytes = :crypto.strong_rand_bytes(@rand_size)

    {Base.url_encode64(bytes, padding: false), :crypto.hash(@hash_algorithm, bytes)}
  end

  @doc """
  Digests a token presented by a client, so it can be searched by equality.

  Returns `:error` for anything that is not a token this module could have
  built — malformed Base64 or the right encoding of the wrong number of bytes.
  Callers treat that as "no such participation", never as an exception: the
  value comes from a cookie or a header and is not to be trusted.

      iex> LiveQuiz.Games.ParticipantToken.hash("not base64!")
      :error

  """
  @spec hash(term()) :: {:ok, binary()} | :error
  def hash(token) when is_binary(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, bytes} when byte_size(bytes) == @rand_size ->
        {:ok, :crypto.hash(@hash_algorithm, bytes)}

      _malformed ->
        :error
    end
  end

  def hash(_token), do: :error

  @doc "How many random bytes a token carries."
  @spec rand_size() :: pos_integer()
  def rand_size, do: @rand_size
end
