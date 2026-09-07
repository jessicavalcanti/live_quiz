defmodule LiveQuiz.Games.Room do
  @moduledoc """
  The primitives every part of a room's life needs, and none of the life itself.

  Opening a room, playing it and ending it are three different concerns living
  in three different modules, and all three read the same row, filter by the
  same notion of "live" and stamp the same kind of timestamp. These are those
  shared pieces — queries and one-line reads, no rules — so that splitting the
  concerns did not mean copying the plumbing three ways.

  The two clocks are here for the same reason. Phase 2's columns are
  second-precision and phase 3's are microsecond, which is deliberate: the
  speed bonus measures the fraction, and rounding it would tie half the room.
  Having both named in one place is what keeps a caller from reaching for the
  wrong one.
  """

  import Ecto.Query

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Quizzes
  alias LiveQuiz.Quizzes.Quiz
  alias LiveQuiz.Repo

  @doc "Now, to the second — the precision the lobby columns are stored in."
  @spec now() :: DateTime.t()
  def now, do: DateTime.utc_now(:second)

  @doc """
  Now, with the fraction of a second.

  The columns of a running match keep it because the speed bonus is measured
  from them; they are never truncated the way the lobby columns are.
  """
  @spec now_usec() :: DateTime.t()
  def now_usec, do: DateTime.utc_now()

  @doc "Reads the room back from the database, keeping what was given if it is gone."
  @spec reload(GameSession.t()) :: GameSession.t()
  def reload(%GameSession{id: id} = session), do: Repo.get(GameSession, id) || session

  @doc "Narrows a query to the rooms that are still live — waiting or running."
  @spec live(Ecto.Queryable.t()) :: Ecto.Query.t()
  def live(query), do: where(query, [s], s.status in ^GameSession.active_statuses())

  @doc "The rooms hosted by the scope user, as a composable query."
  @spec hosted(Scope.t()) :: Ecto.Query.t()
  def hosted(%Scope{} = scope), do: from(s in GameSession, where: s.host_id == ^scope.user.id)

  @doc """
  Fetches one of the scope user's rooms by id.

  A room hosted by somebody else is `{:error, :unauthorized}` rather than
  `:not_found`, because the caller already holds the room and is being told it
  is not theirs to command.
  """
  @spec fetch_hosted(Scope.t(), GameSession.t()) ::
          {:ok, GameSession.t()} | {:error, :unauthorized}
  def fetch_hosted(%Scope{} = scope, %GameSession{id: id}) do
    scope
    |> hosted()
    |> where([s], s.id == ^id)
    |> Repo.one()
    |> case do
      nil -> {:error, :unauthorized}
      %GameSession{} = session -> {:ok, session}
    end
  end

  @doc "Whether the quiz has anything to play, checked when a room opens and when it starts."
  @spec ensure_playable(Quiz.t()) :: :ok | {:error, :quiz_not_playable}
  def ensure_playable(%Quiz{} = quiz) do
    if Quizzes.playable?(quiz), do: :ok, else: {:error, :quiz_not_playable}
  end

  @doc """
  Lets go of everybody still tied to the room, in one statement.

  Only `released_at` is stamped: whoever was there stays recorded as present at
  the end, which is what the history reads back, and clearing the
  one-room-per-account index violates nothing.
  """
  @spec release_participants(integer(), DateTime.t()) :: {non_neg_integer(), nil}
  def release_participants(session_id, at) do
    Participant
    |> where([p], p.game_session_id == ^session_id and is_nil(p.released_at))
    |> Repo.update_all(set: [released_at: at, updated_at: at])
  end
end
