defmodule LiveQuiz.Games.ResultFilters do
  @moduledoc """
  What `quiz_id`, `from` and `to` mean when a listing of results is filtered.

  The same three filters are offered by the API, by the participant's list of
  matches and by the host's history, and each entry point used to convert them
  on its own. They disagreed about the one thing a date filter has to settle —
  where a day ends — so `?to=2026-09-06` meant "up to the last instant of the
  6th" on the screen and "up to midnight starting the 6th" over HTTP, and the
  same request answered with different rows depending on who asked.

  A bare date is a whole day here: `from` opens it at `00:00:00Z` and `to`
  closes it at the last microsecond, which is the only reading under which
  `from=X&to=X` returns the matches played on X. A full ISO 8601 instant is
  taken as given — a client that says exactly when it means is not second
  guessed — and a blank is simply no filter at all.

  Like `LiveQuiz.Pagination`, the meaning lives here once and the strictness is
  the caller's: `parse/1` refuses a value it cannot read, `normalize/1` drops
  it. The API refuses, so a typo answers `422` instead of silently listing
  everything; the screens drop, so a hand-edited address still renders.
  """

  @type t :: %{
          quiz_id: pos_integer() | nil,
          from: DateTime.t() | nil,
          to: DateTime.t() | nil
        }

  @empty %{quiz_id: nil, from: nil, to: nil}

  @doc "The filter that selects everything."
  @spec empty() :: t()
  def empty, do: @empty

  @doc """
  Reads a quiz identifier that has to be there.

  The same rule the `quiz_id` filter uses, minus the right to be absent: this
  is the quiz named in the path of a history endpoint, where a blank is not
  "no filter" but a request that cannot be served. Exposed so that "what is a
  quiz identifier" is not decided twice.
  """
  @spec required_quiz_id(term()) :: {:ok, pos_integer()} | {:error, :invalid_filter}
  def required_quiz_id(value) do
    case quiz_id(value) do
      {:ok, nil} -> {:error, :invalid_filter}
      answer -> answer
    end
  end

  @doc """
  Reads the three filters, refusing anything that is not one of them.

  A blank or absent value is not a refusal — it is the absence of that filter.
  """
  @spec parse(map() | keyword()) :: {:ok, t()} | {:error, :invalid_filter}
  def parse(params) do
    with {:ok, quiz_id} <- fetch_quiz_id(params),
         {:ok, from} <- fetch_date(params, :from, ~T[00:00:00.000000]),
         {:ok, to} <- fetch_date(params, :to, ~T[23:59:59.999999]) do
      {:ok, %{quiz_id: quiz_id, from: from, to: to}}
    end
  end

  @doc """
  Reads the three filters, dropping any value it cannot make sense of.

  Same meaning as `parse/1`, opposite reaction — a filter that cannot be read
  is a filter that was not applied, never an error the screen has to render.
  """
  @spec normalize(map() | keyword()) :: t()
  def normalize(params) do
    case parse(params) do
      {:ok, filters} ->
        filters

      {:error, :invalid_filter} ->
        %{
          quiz_id: drop_on_error(fetch_quiz_id(params)),
          from: drop_on_error(fetch_date(params, :from, ~T[00:00:00.000000])),
          to: drop_on_error(fetch_date(params, :to, ~T[23:59:59.999999]))
        }
    end
  end

  defp drop_on_error({:ok, value}), do: value
  defp drop_on_error({:error, :invalid_filter}), do: nil

  defp fetch_quiz_id(params), do: params |> get(:quiz_id) |> quiz_id()

  defp quiz_id(value) do
    case value do
      blank when blank in [nil, ""] -> {:ok, nil}
      value when is_integer(value) and value > 0 -> {:ok, value}
      value when is_binary(value) -> integer_id(value)
      _value -> {:error, :invalid_filter}
    end
  end

  defp integer_id(value) do
    case Integer.parse(value) do
      {quiz_id, ""} when quiz_id > 0 -> {:ok, quiz_id}
      _not_an_identifier -> {:error, :invalid_filter}
    end
  end

  # `edge` is where a bare date lands: the opening instant of the day for
  # `from`, its closing one for `to`. It is the whole difference between the
  # two filters, and the reason a day is inclusive on both ends.
  defp fetch_date(params, key, edge) do
    case get(params, key) do
      blank when blank in [nil, ""] -> {:ok, nil}
      %DateTime{} = value -> {:ok, value}
      value when is_binary(value) -> parse_date(value, edge)
      _value -> {:error, :invalid_filter}
    end
  end

  defp parse_date(value, edge) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, DateTime.new!(date, edge, "Etc/UTC")}
      {:error, _not_a_bare_date} -> parse_datetime(value)
    end
  end

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid_filter}
    end
  end

  defp get(params, key) when is_list(params), do: Keyword.get(params, key)

  defp get(params, key) when is_map(params) do
    case Map.fetch(params, key) do
      {:ok, value} -> value
      :error -> Map.get(params, Atom.to_string(key))
    end
  end
end
