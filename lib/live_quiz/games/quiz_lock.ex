defmodule LiveQuiz.Games.QuizLock do
  @moduledoc """
  Whether a quiz is locked by a live room.

  It is a module of its own so that `LiveQuiz.Quizzes` can apply the rule
  without depending on the `LiveQuiz.Games` context, which depends on `Quizzes`
  in turn. It only ever reads `game_sessions` and the quiz row — it writes
  nothing.

  The rule is derived from state rather than stored in a column: a quiz is
  locked while at least one room in `waiting` or `in_progress` points at it, and
  becomes editable again the moment the last of them ends.
  """

  import Ecto.Query

  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Quizzes.Quiz
  alias LiveQuiz.Repo

  @doc """
  Whether the quiz has any room in `waiting` or `in_progress`.

  An id that does not exist answers `false`: something with no room is not
  locked.
  """
  @spec locked?(integer() | String.t()) :: boolean()
  def locked?(quiz_id) do
    GameSession
    |> where([s], s.quiz_id == ^quiz_id)
    |> active()
    |> Repo.exists?()
  end

  @doc """
  Composable query that fills the virtual `locked?` field in the selection.

  It is a correlated `EXISTS` inside the `SELECT` itself, not a query per row:
  a paginated listing still resolves in the number of queries it did before.
  The query it is given has to name the quiz source `:quiz`, which is the
  anchor `parent_as/1` correlates against.
  """
  @spec with_lock_flag(Ecto.Query.t()) :: Ecto.Query.t()
  def with_lock_flag(query) do
    from q in query, select_merge: %{locked?: exists(active_sessions_of_parent_quiz())}
  end

  @doc """
  Locks the quiz row with `FOR UPDATE` and answers with its id.

  Taken by both sides of the race — by `LiveQuiz.Quizzes` before writing and by
  `LiveQuiz.Games` before opening a room — it is what closes the window between
  checking the lock and writing: without it the room could be born between the
  two, and the edit would go through anyway.

  Raises `Ecto.NoResultsError` when the quiz does not exist. It only makes sense
  inside a transaction, since the lock is released when that ends.
  """
  @spec lock_quiz!(integer() | String.t()) :: integer()
  def lock_quiz!(quiz_id) do
    Repo.one!(from q in Quiz, where: q.id == ^quiz_id, select: q.id, lock: "FOR UPDATE")
  end

  defp active_sessions_of_parent_quiz do
    GameSession
    |> where([s], s.quiz_id == parent_as(:quiz).id)
    |> active()
    |> select([s], 1)
  end

  defp active(query) do
    where(query, [s], s.status in ^GameSession.active_statuses())
  end
end
