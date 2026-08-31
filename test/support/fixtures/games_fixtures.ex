defmodule LiveQuiz.GamesFixtures do
  @moduledoc """
  Test helpers for creating game sessions and participants.

  They insert through the schemas directly because the `LiveQuiz.Games` context
  does not exist yet (F2-02 onwards), mirroring what `LiveQuiz.QuizzesFixtures`
  did while `LiveQuiz.Quizzes` was still being built.

  Join codes and nicknames come from `System.unique_integer/1`, so parallel
  ExUnit runs never trip over the partial unique indexes.
  """

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.QuizzesFixtures

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Quizzes.Quiz
  alias LiveQuiz.Repo

  @join_code_alphabet String.graphemes("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
  @join_code_length 6
  @join_code_space 32 ** 6

  @doc """
  A join code drawn from the AD-25 alphabet, unique within the test run.
  """
  @spec unique_join_code() :: String.t()
  def unique_join_code do
    [:positive]
    |> System.unique_integer()
    |> rem(@join_code_space)
    |> encode_join_code()
  end

  @doc """
  A nickname unique within the test run, short enough for the 20-character limit.
  """
  @spec unique_nickname() :: String.t()
  def unique_nickname, do: "Ana #{System.unique_integer([:positive])}"

  @doc """
  A 32-byte value shaped like the SHA-256 digest the context will store.
  """
  @spec unique_access_token_hash() :: binary()
  def unique_access_token_hash, do: :crypto.strong_rand_bytes(32)

  @doc """
  Inserts a room, creating the host and the quiz when they are not given.

  Besides the schema fields, `attrs` accepts `:host` (a `%User{}`) and `:quiz`
  (a `%Quiz{}` or `nil`, for a room whose quiz was deleted).
  """
  @spec game_session_fixture(map()) :: GameSession.t()
  def game_session_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    host = Map.get_lazy(attrs, :host, &user_fixture/0)
    quiz = Map.get_lazy(attrs, :quiz, fn -> quiz_fixture(Scope.for_user(host)) end)

    {status, attrs} = attrs |> Map.drop([:host, :quiz]) |> Map.pop(:status)

    attrs =
      Enum.into(attrs, %{
        quiz_title: quiz_title(quiz),
        join_code: unique_join_code()
      })

    %GameSession{host_id: host.id, quiz_id: quiz && quiz.id}
    |> GameSession.create_changeset(attrs)
    |> apply_status(status)
    |> Repo.insert!()
  end

  @doc """
  Inserts a participant in the given room.

  Besides the schema fields, `attrs` accepts `:user` (a `%User{}` for someone
  with an account, or `nil` for a guest).
  """
  @spec participant_fixture(GameSession.t(), map()) :: Participant.t()
  def participant_fixture(%GameSession{} = session, attrs \\ %{}) do
    attrs = Map.new(attrs)
    user = Map.get(attrs, :user)
    lifecycle = Map.take(attrs, [:connection_id, :left_at, :released_at])

    %Participant{
      game_session_id: session.id,
      user_id: user && user.id,
      access_token_hash: Map.get(attrs, :access_token_hash) || unique_access_token_hash(),
      joined_at: Map.get(attrs, :joined_at) || now()
    }
    |> Participant.join_changeset(%{nickname: Map.get(attrs, :nickname) || unique_nickname()})
    |> Participant.connection_changeset(lifecycle)
    |> Repo.insert!()
  end

  @doc "The current instant with the second precision the schemas persist."
  @spec now() :: DateTime.t()
  def now, do: DateTime.truncate(DateTime.utc_now(), :second)

  defp quiz_title(%Quiz{title: title}), do: title
  defp quiz_title(nil), do: "Quiz removido"

  defp apply_status(changeset, nil), do: changeset
  defp apply_status(%Ecto.Changeset{valid?: false} = changeset, _status), do: changeset

  defp apply_status(changeset, status) do
    changeset
    |> Ecto.Changeset.apply_changes()
    |> GameSession.status_changeset(status)
  end

  defp encode_join_code(number) do
    Enum.map_join(1..@join_code_length, fn position ->
      index = number |> div(32 ** (position - 1)) |> rem(32)
      Enum.at(@join_code_alphabet, index)
    end)
  end
end
