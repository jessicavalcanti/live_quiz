defmodule LiveQuiz.Games.Access do
  @moduledoc """
  Who is allowed to see what of a room.

  Three different people can legitimately be looking at the same room — its
  host, a participation, and the account that participation was tied to — and
  the answer is never "is this person logged in" but "is this person one of
  the people this room belongs to". Every read of a match asks one of the two
  questions below, and getting them mixed up is what leaks an answer key or
  hides a ranking from somebody who played.

  The two are deliberately not the same question, and deliberately not the same
  name:

    * `may_watch?/2` — *was* in this room at any point. Wider on purpose:
      finishing a match releases everybody, and the ending screen belongs to
      exactly the people who were just released.
    * `may_read_lobby?/2` — *is* in this room right now. Whoever the room
      already released is no longer one of the people in it.

  The only difference between the two queries is `released_at`, which is
  precisely why they cannot share a name.

  A refusal is always `{:error, :unauthorized}` and never an empty result, so
  the API can answer `403` rather than pretend the room is empty (AD-35).
  """

  import Ecto.Query

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Accounts.User
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Repo

  @typedoc "Whoever is asking: an account, a participation, or nobody."
  @type viewer :: Scope.t() | Participant.t() | nil

  @doc "Whether the viewer may watch this match, now or after it ended."
  @spec may_watch?(GameSession.t(), viewer()) :: boolean()
  def may_watch?(%GameSession{} = session, %Scope{} = scope) do
    session.host_id == scope.user.id or was_in_room?(session, scope)
  end

  def may_watch?(%GameSession{id: session_id}, %Participant{game_session_id: session_id}),
    do: true

  def may_watch?(_session, _viewer), do: false

  @doc "`may_watch?/2` as a step of a `with`."
  @spec ensure_may_watch(GameSession.t(), viewer()) :: :ok | {:error, :unauthorized}
  def ensure_may_watch(%GameSession{} = session, viewer) do
    if may_watch?(session, viewer), do: :ok, else: {:error, :unauthorized}
  end

  @doc "Whether the viewer may read who is in this room right now."
  @spec may_read_lobby?(GameSession.t(), viewer()) :: boolean()
  def may_read_lobby?(%GameSession{} = session, %Scope{} = scope) do
    session.host_id == scope.user.id or still_in_room?(session, scope)
  end

  def may_read_lobby?(%GameSession{id: session_id}, %Participant{
        game_session_id: session_id,
        released_at: nil
      }),
      do: true

  def may_read_lobby?(_session, _viewer), do: false

  @doc """
  Whether the viewer is the host reading their own room.

  It is not an authorization on its own — it is what decides whether the answer
  key travels with a question that is still open.
  """
  @spec host_view?(GameSession.t(), viewer()) :: boolean()
  def host_view?(%GameSession{host_id: host_id}, %Scope{user: %User{id: host_id}}), do: true
  def host_view?(%GameSession{}, _viewer), do: false

  defp was_in_room?(%GameSession{id: session_id}, %Scope{} = scope) do
    Participant
    |> where([p], p.game_session_id == ^session_id and p.user_id == ^scope.user.id)
    |> Repo.exists?()
  end

  defp still_in_room?(%GameSession{id: session_id}, %Scope{} = scope) do
    Participant
    |> where([p], p.game_session_id == ^session_id and p.user_id == ^scope.user.id)
    |> where([p], is_nil(p.released_at))
    |> Repo.exists?()
  end
end
