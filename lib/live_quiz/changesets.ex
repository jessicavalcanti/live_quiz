defmodule LiveQuiz.Changesets do
  @moduledoc """
  The normalizations every schema applies to text on its way in.

  Seven schemas trimmed their strings, and each carried its own two-line copy of
  the same function. They never disagreed, which is exactly what made the
  duplication easy to keep adding to — the eighth schema would have copied it
  too.

  Both functions tolerate a value that is not a string. `update_change/3` only
  runs when the field actually changed, and a `:string` field that failed to
  cast never gets here, so the fallback clause is about not making the schemas
  reason about that at all.
  """

  @doc "Trims surrounding whitespace, leaving anything that is not a string alone."
  @spec trim(term()) :: term()
  def trim(value) when is_binary(value), do: String.trim(value)
  def trim(value), do: value

  @doc """
  Trims and upcases, leaving anything that is not a string alone.

  This is how a join code is stored, so a code read out loud and typed back in
  lowercase still finds its room.
  """
  @spec upcase(term()) :: term()
  def upcase(value) when is_binary(value), do: value |> String.trim() |> String.upcase()
  def upcase(value), do: value
end
