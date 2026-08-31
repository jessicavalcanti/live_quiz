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
  alias LiveQuiz.Games.QuizLock
  alias LiveQuiz.Quizzes.AnswerOption
  alias LiveQuiz.Quizzes.Question
  alias LiveQuiz.Quizzes.Quiz
  alias LiveQuiz.Repo

  @default_page 1
  @default_per_page 20
  @max_per_page 100
  @max_questions 50

  @typedoc """
  What a write can be refused with.

  `:quiz_locked` is deliberately not a changeset: the interface has to tell
  "there is a live room" apart from "these fields are invalid", and the API
  answers 409 for the first and 422 for the second.
  """
  @type write_error :: :quiz_locked | Changeset.t()

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
  query as an aggregate and `locked?` as a correlated `EXISTS`, never as a
  query per row.

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
      |> QuizLock.with_lock_flag()
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
  Fetches one of the scope user's quizzes, with `questions_count` and `locked?`
  filled in.

  Raises `Ecto.NoResultsError` when the quiz does not exist or belongs to
  somebody else.
  """
  @spec get_quiz!(Scope.t(), integer() | String.t()) :: Quiz.t()
  def get_quiz!(%Scope{} = scope, id) do
    scope
    |> owned_quizzes()
    |> where([q], q.id == ^id)
    |> with_questions_count()
    |> QuizLock.with_lock_flag()
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

  Refused with `{:error, :quiz_locked}` while the quiz has a live room (F2-07).
  """
  @spec update_quiz(Scope.t(), Quiz.t(), map()) :: {:ok, Quiz.t()} | {:error, write_error()}
  def update_quiz(%Scope{} = scope, %Quiz{} = quiz, attrs) do
    true = quiz.owner_id == scope.user.id

    while_unlocked(quiz.id, fn ->
      quiz
      |> ensure_questions_count()
      |> Quiz.changeset(attrs)
      |> Repo.update()
      |> or_rollback()
    end)
  end

  @doc """
  Deletes one of the scope user's quizzes.

  Its questions and answer options go with it, through the database cascade.

  Refused with `{:error, :quiz_locked}` while the quiz has a live room (F2-07).
  """
  @spec delete_quiz(Scope.t(), Quiz.t()) :: {:ok, Quiz.t()} | {:error, write_error()}
  def delete_quiz(%Scope{} = scope, %Quiz{} = quiz) do
    true = quiz.owner_id == scope.user.id

    while_unlocked(quiz.id, fn ->
      quiz
      |> ensure_questions_count()
      |> Repo.delete()
      |> or_rollback()
    end)
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

  @doc """
  The largest number of questions a quiz is allowed to hold.

  Callers that need to disable a "new question" affordance ask here instead of
  hardcoding the number, so the limit keeps living in one place.
  """
  @spec max_questions() :: pos_integer()
  def max_questions, do: @max_questions

  @doc """
  Fetches one question of the given quiz, with its answer options preloaded and
  ordered by position.

  Raises `Ecto.NoResultsError` when the question does not exist or the quiz
  belongs to somebody else.
  """
  @spec get_question!(Scope.t(), Quiz.t(), integer() | String.t()) :: Question.t()
  def get_question!(%Scope{} = scope, %Quiz{} = quiz, id) do
    scope
    |> owned_questions()
    |> where([q, quiz: quiz], quiz.id == ^quiz.id and q.id == ^id)
    |> Repo.one!()
    |> Repo.preload(:answer_options)
  end

  @doc """
  Creates a question with exactly #{Question.options_per_question()} answer
  options, in a single transaction.

  The position is computed on the server as the quiz's highest position plus
  one, and is never read from `attrs`. A quiz that already holds
  #{@max_questions} questions returns `{:error, :question_limit_reached}` and
  nothing is written.

  Refused with `{:error, :quiz_locked}` while the quiz has a live room (F2-07).
  """
  @spec create_question(Scope.t(), Quiz.t(), map()) ::
          {:ok, Question.t()} | {:error, write_error()} | {:error, :question_limit_reached}
  def create_question(%Scope{} = scope, %Quiz{} = quiz, attrs) do
    true = quiz.owner_id == scope.user.id

    while_unlocked(quiz.id, fn ->
      if count_questions(quiz) >= @max_questions do
        Repo.rollback(:question_limit_reached)
      else
        insert_question(quiz, attrs)
      end
    end)
  end

  defp insert_question(%Quiz{} = quiz, attrs) do
    %Question{quiz_id: quiz.id}
    |> Question.changeset(put_position(attrs, next_question_position(quiz)))
    |> Repo.insert()
    |> case do
      {:ok, question} -> Repo.preload(question, :answer_options)
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  @doc """
  Updates the question text and its answer options, in a single transaction.

  The position is not touched: reordering belongs to F1-08.

  Refused with `{:error, :quiz_locked}` while the quiz has a live room (F2-07).

  Raises `Ecto.NoResultsError` when the question belongs to somebody else.
  """
  @spec update_question(Scope.t(), Question.t(), map()) ::
          {:ok, Question.t()} | {:error, write_error()}
  def update_question(%Scope{} = scope, %Question{} = question, attrs) do
    question = fetch_owned_question!(scope, question.id)

    while_unlocked(question.quiz_id, fn ->
      question
      |> clear_correct_option(attrs)
      |> Question.changeset(drop_position(attrs))
      |> Repo.update()
      |> case do
        {:ok, updated} -> Repo.preload(updated, :answer_options, force: true)
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # Clears the current correct option before applying a new set, so marking a
  # different one can never trip the partial unique index halfway through.
  # Reloading afterwards is what makes it safe: the option that stays correct
  # becomes a real change again instead of being skipped as a no-op.
  #
  # Only worth doing when the caller actually sent options — an edit that just
  # rewrites the question text must leave the stored set exactly as it is.
  defp clear_correct_option(%Question{} = question, attrs) do
    if carries_options?(attrs) do
      Repo.update_all(
        from(o in AnswerOption, where: o.question_id == ^question.id and o.is_correct),
        set: [is_correct: false]
      )

      Repo.preload(question, :answer_options, force: true)
    else
      Repo.preload(question, :answer_options)
    end
  end

  defp carries_options?(attrs) do
    Map.has_key?(attrs, :answer_options) or Map.has_key?(attrs, "answer_options")
  end

  @doc """
  Deletes the question and closes the gap it leaves, so the quiz keeps a dense
  `1..n` sequence. Runs in a single transaction; the answer options go with it
  through the database cascade.

  Refused with `{:error, :quiz_locked}` while the quiz has a live room (F2-07).

  Raises `Ecto.NoResultsError` when the question belongs to somebody else.
  """
  @spec delete_question(Scope.t(), Question.t()) ::
          {:ok, Question.t()} | {:error, write_error()}
  def delete_question(%Scope{} = scope, %Question{} = question) do
    question = fetch_owned_question!(scope, question.id)

    while_unlocked(question.quiz_id, fn -> remove_question(question) end)
  end

  @doc """
  Moves the question one place up or down inside its quiz.

  Returns `{:ok, :unchanged}` when the question already sits at the matching
  edge — moving the first one up is a successful no-op, not an error.

  Refused with `{:error, :quiz_locked}` while the quiz has a live room (F2-07).

  Raises `Ecto.NoResultsError` when the question belongs to somebody else.
  """
  @spec move_question(Scope.t(), Question.t(), :up | :down) ::
          {:ok, Question.t()} | {:ok, :unchanged} | {:error, write_error()}
  def move_question(%Scope{} = scope, %Question{} = question, direction)
      when direction in [:up, :down] do
    question = fetch_owned_question!(scope, question.id)

    while_unlocked(question.quiz_id, fn -> relocate_question(question, direction) end)
  end

  defp remove_question(%Question{} = question) do
    question = lock_question!(question.id)

    case Repo.delete(question) do
      {:ok, deleted} -> close_position_gap(deleted)
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp close_position_gap(%Question{} = deleted) do
    Repo.update_all(
      from(q in Question,
        where: q.quiz_id == ^deleted.quiz_id and q.position > ^deleted.position
      ),
      inc: [position: -1]
    )

    deleted
  end

  defp relocate_question(%Question{} = question, direction) do
    question = lock_question!(question.id)
    target = target_position(question.position, direction)

    case lock_question_at(question.quiz_id, target) do
      nil -> :unchanged
      neighbour -> swap_positions(question, neighbour)
    end
  end

  defp target_position(position, :up), do: position - 1
  defp target_position(position, :down), do: position + 1

  # Both updates happen inside one transaction, so the intermediate state where
  # two questions share a position never reaches a constraint check: the unique
  # index on (quiz_id, position) is DEFERRABLE INITIALLY DEFERRED. No temporary
  # position is needed.
  defp swap_positions(%Question{} = question, %Question{} = neighbour) do
    moved_at = DateTime.utc_now(:second)

    reposition(neighbour, question.position, moved_at)
    reposition(question, neighbour.position, moved_at)

    %{question | position: neighbour.position, updated_at: moved_at}
  end

  defp reposition(%Question{} = question, position, moved_at) do
    Repo.update_all(
      from(q in Question, where: q.id == ^question.id),
      set: [position: position, updated_at: moved_at]
    )
  end

  # Ownership was already proven by the caller's `fetch_owned_question!/2`, so
  # the row is locked on its own and `FOR UPDATE` never reaches across the join
  # to the quiz row — that one is taken separately, and always first.
  defp lock_question!(id) do
    Repo.one!(from q in Question, where: q.id == ^id, lock: "FOR UPDATE")
  end

  defp lock_question_at(quiz_id, position) do
    Repo.one(
      from q in Question,
        where: q.quiz_id == ^quiz_id and q.position == ^position,
        lock: "FOR UPDATE"
    )
  end

  @doc """
  Returns a changeset for tracking question changes in a form.

  A brand new question gets its #{Question.options_per_question()} blank options
  so the form has rows to render.
  """
  @spec change_question(Question.t(), map()) :: Changeset.t()
  def change_question(%Question{} = question, attrs \\ %{}) do
    question
    |> prepare_options_for_form(attrs)
    |> Question.changeset(attrs)
  end

  @doc """
  Returns a new question carrying #{Question.options_per_question()} blank
  options in positions 1..#{Question.options_per_question()}.
  """
  @spec new_question() :: Question.t()
  def new_question do
    %Question{answer_options: blank_options()}
  end

  defp fetch_owned_question!(%Scope{} = scope, id) do
    scope
    |> owned_questions()
    |> where([q], q.id == ^id)
    |> Repo.one!()
  end

  defp owned_questions(%Scope{} = scope) do
    from q in Question,
      join: quiz in assoc(q, :quiz),
      as: :quiz,
      where: quiz.owner_id == ^scope.user.id
  end

  defp count_questions(%Quiz{} = quiz) do
    Repo.aggregate(from(q in Question, where: q.quiz_id == ^quiz.id), :count)
  end

  defp next_question_position(%Quiz{} = quiz) do
    highest = Repo.one(from q in Question, where: q.quiz_id == ^quiz.id, select: max(q.position))

    (highest || 0) + 1
  end

  # The blank options exist only so an empty form has rows to render. Once the
  # form comes back with options in the params, they have to go: matching four
  # unsaved blanks against four id-less params would collapse them by their nil
  # primary key.
  defp prepare_options_for_form(%Question{id: nil} = question, attrs) do
    if carries_options?(attrs) do
      %{question | answer_options: []}
    else
      %{question | answer_options: blank_options()}
    end
  end

  defp prepare_options_for_form(%Question{} = question, _attrs), do: question

  defp blank_options do
    for position <- 1..Question.options_per_question() do
      %AnswerOption{position: position, is_correct: false}
    end
  end

  defp put_position(attrs, position) do
    if string_keyed?(attrs) do
      Map.put(attrs, "position", position)
    else
      Map.put(attrs, :position, position)
    end
  end

  defp drop_position(attrs) do
    attrs |> Map.delete(:position) |> Map.delete("position")
  end

  defp string_keyed?(attrs), do: Enum.any?(Map.keys(attrs), &is_binary/1)

  # Every write of this context goes through here: the quiz row is taken with
  # `FOR UPDATE` first and the lock is only then read, so a room opened halfway
  # through waits for the transaction instead of sneaking in between the check
  # and the write. `LiveQuiz.Games` takes the same row lock before inserting a
  # room, which is what makes the two orders exclusive.
  defp while_unlocked(quiz_id, fun) do
    Repo.transaction(fn ->
      QuizLock.lock_quiz!(quiz_id)

      if QuizLock.locked?(quiz_id) do
        Repo.rollback(:quiz_locked)
      else
        fun.()
      end
    end)
  end

  # Inside a transaction an invalid changeset has to become a rollback, or the
  # caller would get `{:ok, {:error, changeset}}` from `Repo.transaction/1`.
  defp or_rollback({:ok, record}), do: record
  defp or_rollback({:error, %Changeset{} = changeset}), do: Repo.rollback(changeset)

  # The `:quiz` binding is the anchor `QuizLock.with_lock_flag/1` correlates its
  # `EXISTS` against, so every read that goes through here can carry `locked?`.
  defp owned_quizzes(%Scope{} = scope) do
    from q in Quiz, as: :quiz, where: q.owner_id == ^scope.user.id
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
