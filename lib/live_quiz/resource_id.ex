defmodule LiveQuiz.ResourceId do
  @moduledoc """
  What can and cannot be the id of a resource, decided once.

  Ids reach the application from paths and query strings, where everything is a
  string and anything can be typed. `"abc"`, `"1.5"`, `"-3"` and a number wider
  than a `bigint` are all values no row could ever have, and each of them used
  to be answered differently: some controllers rescued `Ecto.Query.CastError`
  into a 404, others let it become a 400, and a LiveView reading the same id
  produced a third page (R30).

  None of that is a decision the controllers should be making separately. An
  identifier that names no possible resource is a resource that is not there,
  which is a 404 — the same answer somebody else's quiz already gets, and for
  the same reason: a client learns nothing about what exists from a value that
  could not exist.

  A malformed *filter* or *payload* is a different thing and keeps its own
  answer, `422`: those describe a request the caller can fix, not a resource
  that is missing.
  """

  # The widest value the `bigserial` primary keys can hold. Past it the cast
  # itself fails, and the failure is the caller's arithmetic rather than a
  # database error worth surfacing.
  @max_id 9_223_372_036_854_775_807

  @doc "The largest id any row of this application can have."
  @spec max() :: pos_integer()
  def max, do: @max_id

  @doc """
  Reads an id, or answers `:error` for anything that is not one.

  Accepts an integer or the string form of one. Zero, negatives, fractions,
  trailing characters, lists, maps and values wider than a `bigint` are all
  `:error`.
  """
  @spec cast(term()) :: {:ok, pos_integer()} | :error
  def cast(value) when is_integer(value) and value > 0 and value <= @max_id, do: {:ok, value}

  def cast(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> cast(id)
      _not_a_whole_number -> :error
    end
  end

  def cast(_value), do: :error

  @doc """
  Reads an id or raises the same `Ecto.NoResultsError` a missing row raises.

  This is what the read functions of the contexts use, so an impossible id and
  an id nobody owns end at the same place — and so a LiveView and a controller
  reading the same path answer the same thing.
  """
  @spec cast!(term(), module()) :: pos_integer()
  def cast!(value, queryable) do
    case cast(value) do
      {:ok, id} -> id
      :error -> raise Ecto.NoResultsError, queryable: queryable
    end
  end
end
