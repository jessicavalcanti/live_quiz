defmodule LiveQuiz.Quizzes do
  @moduledoc """
  Business rules for quizzes, questions and answer options.

  Every public function takes a `LiveQuiz.Accounts.Scope` as its first argument
  and filters by owner **inside the query**. A quiz that belongs to somebody
  else is indistinguishable from a quiz that does not exist: reads raise
  `Ecto.NoResultsError`, which becomes a 404 in the LiveViews and in the API.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Quizzes.Question
  alias LiveQuiz.Quizzes.Quiz
  alias LiveQuiz.Repo

  @default_page 1
  @default_per_page 20
  @max_per_page 100

  @typedoc "A page of quizzes, as returned by `list_quizzes/2`."
  @type page :: %{
          entries: [Quiz.t()],
          page: pos_integer(),
          per_page: pos_integer(),
          total_entries: non_neg_integer(),
          total_pages: non_neg_integer()
        }

  @doc """
  Lists the quizzes owned by the scope user, paginated and newest first.

  Resolves in exactly two queries — one for the page, one for the total —
  no matter how many rows come back: the question count travels with the page
  query as an aggregate, never as a query per row.

  ## Options

    * `:page` — defaults to `#{@default_page}`, minimum `1`
    * `:per_page` — defaults to `#{@default_per_page}`, from `1` to `#{@max_per_page}`
    * `:search` — case-insensitive match on the title; blank terms are ignored

  Out-of-range or non-numeric pagination values fall back to the defaults, and a
  page past the end returns `entries: []` rather than an error.
  """
  @spec list_quizzes(Scope.t(), keyword()) :: page()
  def list_quizzes(%Scope{} = scope, opts \\ []) do
    page = normalize_page(Keyword.get(opts, :page))
    per_page = normalize_per_page(Keyword.get(opts, :per_page))

    query = scope |> owned_quizzes() |> search_by_title(Keyword.get(opts, :search))

    entries =
      query
      |> with_questions_count()
      |> order_by([q], desc: q.updated_at, desc: q.id)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    total_entries = Repo.aggregate(query, :count, :id)

    %{
      entries: entries,
      page: page,
      per_page: per_page,
      total_entries: total_entries,
      total_pages: ceil(total_entries / per_page)
    }
  end

  @doc """
  Fetches one of the scope user's quizzes, with `questions_count` filled in.

  Raises `Ecto.NoResultsError` when the quiz does not exist or belongs to
  somebody else.
  """
  @spec get_quiz!(Scope.t(), integer() | String.t()) :: Quiz.t()
  def get_quiz!(%Scope{} = scope, id) do
    scope
    |> owned_quizzes()
    |> where([q], q.id == ^id)
    |> with_questions_count()
    |> Repo.one!()
  end

  @doc """
  Same as `get_quiz!/2`, with questions and answer options preloaded and
  ordered by position.
  """
  @spec get_quiz_with_questions!(Scope.t(), integer() | String.t()) :: Quiz.t()
  def get_quiz_with_questions!(%Scope{} = scope, id) do
    scope
    |> get_quiz!(id)
    |> Repo.preload(questions: [:answer_options])
  end

  @doc """
  Creates a quiz owned by the scope user.

  The owner comes from the scope and is never read from `attrs`.
  """
  @spec create_quiz(Scope.t(), map()) :: {:ok, Quiz.t()} | {:error, Changeset.t()}
  def create_quiz(%Scope{} = scope, attrs) do
    %Quiz{owner_id: scope.user.id, questions_count: 0}
    |> Quiz.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates one of the scope user's quizzes.
  """
  @spec update_quiz(Scope.t(), Quiz.t(), map()) :: {:ok, Quiz.t()} | {:error, Changeset.t()}
  def update_quiz(%Scope{} = scope, %Quiz{} = quiz, attrs) do
    true = quiz.owner_id == scope.user.id

    quiz
    |> ensure_questions_count()
    |> Quiz.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes one of the scope user's quizzes.

  Its questions and answer options go with it, through the database cascade.
  """
  @spec delete_quiz(Scope.t(), Quiz.t()) :: {:ok, Quiz.t()} | {:error, Changeset.t()}
  def delete_quiz(%Scope{} = scope, %Quiz{} = quiz) do
    true = quiz.owner_id == scope.user.id

    quiz
    |> ensure_questions_count()
    |> Repo.delete()
  end

  @doc """
  Returns a changeset for tracking quiz changes in a form.
  """
  @spec change_quiz(Quiz.t(), map()) :: Changeset.t()
  def change_quiz(%Quiz{} = quiz, attrs \\ %{}) do
    Quiz.changeset(quiz, attrs)
  end

  @doc """
  Tells whether a quiz can already be played, meaning it has at least one
  question.

  Reads the virtual `questions_count` that every read function above fills in,
  so it runs no query of its own. A quiz assembled by hand, without that field,
  raises `ArgumentError` instead of silently answering `false`.
  """
  @spec playable?(Quiz.t()) :: boolean()
  def playable?(%Quiz{questions_count: count}) when is_integer(count), do: count > 0

  def playable?(%Quiz{} = quiz) do
    raise ArgumentError,
          "playable?/1 exige um quiz com questions_count preenchido, recebido: #{inspect(quiz)}"
  end

  defp owned_quizzes(%Scope{} = scope) do
    from q in Quiz, where: q.owner_id == ^scope.user.id
  end

  defp with_questions_count(query) do
    from q in query,
      left_join: qs in assoc(q, :questions),
      group_by: q.id,
      select: %{q | questions_count: count(qs.id)}
  end

  defp search_by_title(query, term) when is_binary(term) do
    case String.trim(term) do
      "" -> query
      trimmed -> from q in query, where: ilike(q.title, ^"%#{escape_like(trimmed)}%")
    end
  end

  defp search_by_title(query, _term), do: query

  # `\` first, so the escapes added below are not escaped a second time.
  defp escape_like(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp normalize_page(value) do
    case to_integer(value) do
      page when is_integer(page) and page >= 1 -> page
      _other -> @default_page
    end
  end

  defp normalize_per_page(value) do
    case to_integer(value) do
      per_page when is_integer(per_page) and per_page >= 1 and per_page <= @max_per_page ->
        per_page

      _other ->
        @default_per_page
    end
  end

  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp to_integer(_value), do: nil

  defp ensure_questions_count(%Quiz{questions_count: count} = quiz) when is_integer(count) do
    quiz
  end

  defp ensure_questions_count(%Quiz{} = quiz) do
    count = Repo.aggregate(from(q in Question, where: q.quiz_id == ^quiz.id), :count)

    %{quiz | questions_count: count}
  end
end
