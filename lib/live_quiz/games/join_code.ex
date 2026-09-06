defmodule LiveQuiz.Games.JoinCode do
  @moduledoc """
  The short code a host reads out loud so people can find the room.

  The alphabet has 32 unambiguous symbols (AD-25): `O`/`0` and `I`/`1` are left
  out, which are exactly the pairs someone mistypes when copying a code from a
  projector. Six characters give 32⁶ ≈ 1.07 billion combinations, wide enough
  that guessing one by hand is not worth the trouble. Both the alphabet and the
  length are read from `LiveQuiz.Games.GameSession`, which is also where the
  database check constraint that mirrors them is declared.

  The bytes come from `:crypto.strong_rand_bytes/1`, never from `:rand`: the
  code is a short-lived secret and must not be predictable from the instant the
  room was opened. Each byte contributes its five lowest bits, and because 256
  is a multiple of 32 every symbol stays equally likely.

  Uniqueness is **not** checked here. The context inserts the code and lets the
  partial unique index refuse a duplicate, retrying up to `max_attempts/0`
  times — asking the database first would leave a window for two rooms to pick
  the same code between the read and the write.
  """

  import Bitwise

  alias LiveQuiz.Games.GameSession

  @alphabet GameSession.join_code_alphabet()
  @symbols @alphabet |> String.graphemes() |> List.to_tuple()
  @length GameSession.join_code_length()
  @max_attempts 5
  @format Regex.compile!("^[#{@alphabet}]{#{@length}}$")

  @doc """
  Generates a random code of #{@length} characters from the unambiguous alphabet.

      iex> code = LiveQuiz.Games.JoinCode.generate()
      iex> LiveQuiz.Games.JoinCode.valid_format?(code)
      true

  """
  @spec generate() :: String.t()
  def generate do
    @length
    |> :crypto.strong_rand_bytes()
    |> :binary.bin_to_list()
    |> Enum.map_join(&elem(@symbols, band(&1, tuple_size(@symbols) - 1)))
  end

  @doc """
  Normalizes a typed code: trims the ends and upcases it.

  Confusable characters are deliberately left alone. Reading `0` as `O` would
  make two different codes point at the same room and quietly halve the space
  the uniqueness index protects — someone who types `0` gets "room not found".

      iex> LiveQuiz.Games.JoinCode.normalize(" k7p4q2 ")
      "K7P4Q2"

  """
  @spec normalize(String.t()) :: String.t()
  def normalize(code) when is_binary(code), do: code |> String.trim() |> String.upcase()

  @doc """
  Tells whether a string is shaped like a code, so a lookup can be refused
  without touching the database.

  Expects an already normalized value: lowercase input is not a valid code.

      iex> LiveQuiz.Games.JoinCode.valid_format?("K7P4Q2")
      true

      iex> LiveQuiz.Games.JoinCode.valid_format?("K7P4Q0")
      false

  """
  @spec valid_format?(term()) :: boolean()
  def valid_format?(code) when is_binary(code), do: Regex.match?(@format, code)
  def valid_format?(_code), do: false

  @doc "How many times the context retries the insert after a code collision."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts
end
