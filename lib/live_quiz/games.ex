defmodule LiveQuiz.Games do
  @moduledoc """
  Business rules for the rooms a host opens from a quiz.

  A room is created from a quiz the caller owns and carries a join code the
  host reads out loud. Two rules decide who may open one, and both cross tables
  that no single index can cover: a person keeps **one live room at a time**,
  and someone already taking part in another room may not host at all. They are
  checked inside a transaction guarded by `pg_advisory_xact_lock/2` on the
  caller's account, so two browser tabs of the same person are serialized
  without ever blocking anybody else.

  Reads by the host take a `LiveQuiz.Accounts.Scope` and filter by owner inside
  the query: a room someone else hosts is indistinguishable from a room that
  does not exist. The lookup people use to enter a room, `get_game_session_by_code/1`,
  is deliberately unscoped — the code is the credential — and only ever answers
  with live rooms.

  ## Test seam

  `:join_code_generator` in the `:live_quiz` application environment replaces
  the code generator with a zero-arity function, which is how the collision
  retry is exercised. It is unset everywhere but in those tests.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Changeset
  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.JoinCode
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Quizzes
  alias LiveQuiz.Quizzes.Quiz
  alias LiveQuiz.Repo

  # Advisory locks are a single namespace shared by the whole application, so
  # the first key is a class: `1` means "the identity of one person". Stories
  # that also serialize per account (F2-03, F2-05) must reuse it, and anything
  # locking on a different subject must pick another class.
  @identity_lock_class 1

  @doc """
  Opens a room for the given quiz, hosted by the scope user.

  The quiz must belong to the scope and have at least one question. The user
  must neither host another live room nor be taking part in one.

  Raises `Ecto.NoResultsError` when the quiz does not exist or belongs to
  somebody else, which the callers turn into a 404.
  """
  @spec create_game_session(Scope.t(), integer() | String.t()) ::
          {:ok, GameSession.t()}
          | {:error, :quiz_not_playable}
          | {:error, :host_already_in_session}
          | {:error, :already_participating}
          | {:error, :code_generation_failed}
          | {:error, Changeset.t()}
  def create_game_session(%Scope{} = scope, quiz_id) do
    Repo.transaction(fn ->
      lock_identity(scope.user.id)
      quiz = Quizzes.get_quiz!(scope, quiz_id)

      with :ok <- ensure_playable(quiz),
           :ok <- ensure_not_hosting(scope),
           :ok <- ensure_not_participating(scope),
           {:ok, session} <- insert_with_join_code(scope, quiz, JoinCode.max_attempts()) do
        session
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Fetches a room hosted by the scope user.

  Raises `Ecto.NoResultsError` when the room does not exist or is hosted by
  somebody else.
  """
  @spec get_game_session!(Scope.t(), integer() | String.t()) :: GameSession.t()
  def get_game_session!(%Scope{} = scope, id) do
    scope
    |> hosted_sessions()
    |> where([s], s.id == ^id)
    |> Repo.one!()
  end

  @doc """
  Fetches a **live** room by its code, without a scope, trimming and upcasing
  the value first so a code typed in lowercase still works.

  A code that cannot exist is rejected before any query runs. Rooms that are
  over are never returned: a cancelled or expired room is not reopened, and its
  code is free for a new room to take.
  """
  @spec get_game_session_by_code(String.t()) :: {:ok, GameSession.t()} | {:error, :not_found}
  def get_game_session_by_code(code) when is_binary(code) do
    normalized = JoinCode.normalize(code)

    if JoinCode.valid_format?(normalized) do
      GameSession
      |> where([s], s.join_code == ^normalized)
      |> live()
      |> Repo.one()
      |> case do
        nil -> {:error, :not_found}
        %GameSession{} = session -> {:ok, session}
      end
    else
      {:error, :not_found}
    end
  end

  def get_game_session_by_code(_code), do: {:error, :not_found}

  @doc "Returns the live room hosted by the scope user, if there is one."
  @spec get_active_session_for_host(Scope.t()) :: GameSession.t() | nil
  def get_active_session_for_host(%Scope{} = scope) do
    scope
    |> hosted_sessions()
    |> live()
    |> Repo.one()
  end

  @doc """
  Tells whether the scope user is tied to any room, hosting or taking part in it.

  Someone who left a room but was not released yet still counts: the seat is
  theirs until the room lets it go (AD-27).
  """
  @spec engaged_in_session?(Scope.t()) :: boolean()
  def engaged_in_session?(%Scope{} = scope) do
    hosting?(scope) or participating?(scope)
  end

  defp ensure_playable(%Quiz{} = quiz) do
    if Quizzes.playable?(quiz), do: :ok, else: {:error, :quiz_not_playable}
  end

  defp ensure_not_hosting(%Scope{} = scope) do
    if hosting?(scope), do: {:error, :host_already_in_session}, else: :ok
  end

  defp ensure_not_participating(%Scope{} = scope) do
    if participating?(scope), do: {:error, :already_participating}, else: :ok
  end

  defp hosting?(%Scope{} = scope) do
    scope |> hosted_sessions() |> live() |> Repo.exists?()
  end

  defp participating?(%Scope{} = scope) do
    Participant
    |> where([p], p.user_id == ^scope.user.id and is_nil(p.released_at))
    |> Repo.exists?()
  end

  defp insert_with_join_code(_scope, _quiz, 0), do: {:error, :code_generation_failed}

  defp insert_with_join_code(%Scope{} = scope, %Quiz{} = quiz, attempts_left) do
    %GameSession{host_id: scope.user.id, quiz_id: quiz.id}
    |> GameSession.create_changeset(%{quiz_title: quiz.title, join_code: generate_join_code()})
    # A rejected insert would poison the surrounding transaction and take the
    # retry down with it, so each attempt gets its own savepoint to roll back to.
    |> Repo.insert(mode: :savepoint)
    |> case do
      {:ok, %GameSession{} = session} ->
        {:ok, session}

      {:error, %Changeset{} = changeset} ->
        handle_insert_error(scope, quiz, changeset, attempts_left)
    end
  end

  defp handle_insert_error(scope, quiz, changeset, attempts_left) do
    cond do
      taken?(changeset, :join_code) ->
        # Astronomically unlikely with 32⁶ codes, so a collision is worth a
        # warning: it is either remarkable luck or a broken generator.
        Logger.warning(
          "join code for host #{scope.user.id} collided with a live room, " <>
            "#{attempts_left - 1} attempt(s) left"
        )

        insert_with_join_code(scope, quiz, attempts_left - 1)

      # The advisory lock already serializes the same person, so this only
      # fires if the lock is bypassed; answering with the same reason as the
      # explicit check keeps the contract stable either way.
      taken?(changeset, :host_id) ->
        {:error, :host_already_in_session}

      true ->
        {:error, changeset}
    end
  end

  defp taken?(%Changeset{errors: errors}, field) do
    Enum.any?(errors, fn
      {^field, {_message, opts}} -> opts[:constraint] == :unique
      _other_field -> false
    end)
  end

  defp generate_join_code do
    case Application.get_env(:live_quiz, :join_code_generator) do
      nil -> JoinCode.generate()
      generator when is_function(generator, 0) -> generator.()
    end
  end

  # Serializes every room decision taken on behalf of one account. The lock is
  # released when the transaction ends, and it is taken before any read so the
  # checks below cannot race against a concurrent insert.
  defp lock_identity(user_id) do
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@identity_lock_class, user_id])
  end

  defp hosted_sessions(%Scope{} = scope) do
    from s in GameSession, where: s.host_id == ^scope.user.id
  end

  defp live(query) do
    where(query, [s], s.status in ^GameSession.active_statuses())
  end
end
