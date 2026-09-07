defmodule LiveQuiz.Pagination do
  @moduledoc """
  What `page` and `per_page` mean, decided in one place.

  Three listings paginate — the quizzes of an account, the results of a
  participant and the history of a host — and each one had grown its own pair of
  normalizers. They agreed on the numbers and disagreed on everything else, which
  is how `/api/v1/quizzes?per_page=101` came to answer `200` with a page of 20
  while `/api/v1/users/me/game-results?per_page=101` answered `422`.

  The meaning of a value lives here; how strict a caller is about a bad one is
  the caller's choice, and there are exactly two:

    * `parse/2` refuses — it is what the API plugs into a `with`, so a client
      that asked for something impossible is told so instead of quietly reading
      a different page than the one it requested.
    * `normalize/2` falls back — it is what the contexts use, so a screen driven
      by a hand-edited query string renders the first page instead of crashing.

  Both read the same primitives, so "what is a valid `per_page`" cannot drift
  between them again. Keyword lists and maps are both accepted, with string or
  atom keys, because the callers are a controller reading `conn.params`, a
  LiveView reading `handle_params` and a context called from a test.
  """

  @default_page 1
  @default_per_page 20
  @max_per_page 100

  # `page * per_page` becomes an `OFFSET`, and a page number nobody could ever
  # reach turns into either a bigint Postgres refuses or a scan it should never
  # be asked to do. Ten thousand pages of a hundred rows is a million rows deep,
  # which is far past anything a person clicks to and far short of anything that
  # breaks (R30). Beyond that the answer is "that is not a page", not a query.
  @max_page 10_000

  @type t :: %{page: pos_integer(), per_page: pos_integer()}

  @doc "The page a request that named none is asking for."
  @spec default_page() :: pos_integer()
  def default_page, do: @default_page

  @doc "How many rows a request that named no size gets."
  @spec default_per_page() :: pos_integer()
  def default_per_page, do: @default_per_page

  @doc "The largest page size anybody may ask for."
  @spec max_per_page() :: pos_integer()
  def max_per_page, do: @max_per_page

  @doc "The highest page number anybody may ask for."
  @spec max_page() :: pos_integer()
  def max_page, do: @max_page

  @doc """
  Reads pagination, refusing anything that is not a page anybody could have.

  A missing value is not a refusal — it is the default. A present one that is
  not a positive integer, a `page` past `#{@max_page}` or a `per_page` past
  `#{@max_per_page}` is.

  ## Options

    * `:per_page` — the default page size for this listing, when it is not
      `#{@default_per_page}`
  """
  @spec parse(map() | keyword(), keyword()) :: {:ok, t()} | {:error, :invalid_filter}
  def parse(params, opts \\ []) do
    with {:ok, page} <- fetch_page(params),
         {:ok, per_page} <- fetch_per_page(params, opts) do
      {:ok, %{page: page, per_page: per_page}}
    end
  end

  @doc """
  Reads pagination, falling back to the defaults for anything unusable.

  Same meaning as `parse/2`, opposite reaction: this one never fails, which is
  what a screen needs when the numbers come from an address somebody typed.
  """
  @spec normalize(map() | keyword(), keyword()) :: t()
  def normalize(params, opts \\ []) do
    case parse(params, opts) do
      {:ok, pagination} -> pagination
      {:error, :invalid_filter} -> fallback(params, opts)
    end
  end

  defp fallback(params, opts) do
    page =
      case fetch_page(params) do
        {:ok, page} -> page
        {:error, :invalid_filter} -> @default_page
      end

    per_page =
      case fetch_per_page(params, opts) do
        {:ok, per_page} -> per_page
        {:error, :invalid_filter} -> Keyword.get(opts, :per_page, @default_per_page)
      end

    %{page: page, per_page: per_page}
  end

  defp fetch_page(params) do
    case get(params, :page) do
      blank when blank in [nil, ""] -> {:ok, @default_page}
      value -> value |> positive_integer() |> at_most(@max_page)
    end
  end

  defp fetch_per_page(params, opts) do
    default = Keyword.get(opts, :per_page, @default_per_page)

    case get(params, :per_page) do
      blank when blank in [nil, ""] -> {:ok, default}
      value -> value |> positive_integer() |> at_most(@max_per_page)
    end
  end

  defp at_most({:ok, value}, ceiling) when value <= ceiling, do: {:ok, value}
  defp at_most(_past_the_ceiling_or_error, _ceiling), do: {:error, :invalid_filter}

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _not_a_whole_positive_number -> {:error, :invalid_filter}
    end
  end

  defp positive_integer(_value), do: {:error, :invalid_filter}

  # The callers disagree on their container and on the shape of their keys, and
  # none of that is a decision worth making three times.
  defp get(params, key) when is_list(params), do: Keyword.get(params, key)

  defp get(params, key) when is_map(params) do
    case Map.fetch(params, key) do
      {:ok, value} -> value
      :error -> Map.get(params, Atom.to_string(key))
    end
  end
end
