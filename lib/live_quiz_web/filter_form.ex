defmodule LiveQuizWeb.FilterForm do
  @moduledoc """
  The query-string half of the two filtered listings.

  `GameResultLive.Index` and `GameHistoryLive.Index` show the same three
  filters over different rows, and each had grown its own copy of the same
  three chores: fill the blanks so the form has something to render, drop the
  blanks so they do not travel in the address, and turn a date into an instant.
  The copies had drifted — one dropped blank values before querying and the
  other did not, which is the only reason `quiz_id=` reached the database as an
  empty string on just one of the two screens.

  The last of those chores now belongs to `LiveQuiz.Games.ResultFilters`, which
  is also what the API reads, so a day means the same thing on both. What is
  left here is the part that is genuinely about a form: which keys exist, and
  what a blank one looks like on the way in and on the way out.
  """

  @keys ~w(quiz_id from to)
  @blank Map.new(@keys, &{&1, ""})

  @doc "The filter keys the two listings accept, in the order the form shows them."
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc """
  What the form renders: every key present, missing ones blank.

  The template reads `@filters["quiz_id"]`, so the keys are strings whether the
  address carried them or not.
  """
  @spec from_params(map()) :: %{optional(String.t()) => String.t()}
  def from_params(params) do
    Map.merge(@blank, Map.take(params, @keys))
  end

  @doc "The filters worth putting in an address: the ones somebody actually filled."
  @spec filled(map()) :: %{optional(String.t()) => String.t()}
  def filled(filters) do
    filters |> Map.take(@keys) |> Map.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  @doc """
  The query string for a page of a filtered listing.

  Blank filters are left out so the address says what is actually being
  filtered, and `page` always travels so a link is not read as "back to the
  first page".
  """
  @spec query(map(), pos_integer()) :: map()
  def query(filters, page) do
    filters |> filled() |> Map.put("page", page)
  end
end
