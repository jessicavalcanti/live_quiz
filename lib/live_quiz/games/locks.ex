defmodule LiveQuiz.Games.Locks do
  @moduledoc """
  The advisory locks a room is serialized by, and the order they are taken in.

  Postgres advisory locks live in one namespace shared by the whole
  application, so the first key of every one of them is a *class* saying what
  the second key identifies. Keeping the classes in one module is the point:
  two callers that picked the same class for different subjects would block
  each other for no reason, and two that picked different classes for the same
  subject would not block at all — the failure nobody notices until two browser
  tabs both win.

  | Class | Second key | Serializes |
  |---|---|---|
  | `1` | account id | one person's rooms — hosting and taking part |
  | `2` | room id | the 25 seats of one room |
  | `3` | room id | the progress of one match, question to question |

  **Order matters.** Anything taking both the identity and the seats lock takes
  identity first, always, which is what keeps `join_game_session/4` from
  deadlocking against `rejoin_game_session/2`. The match lock is taken alone —
  the commands that move a match take nothing else — so it has no order to keep
  and cannot deadlock against anything.

  Every one of them is an `xact` lock: it is released when the transaction ends,
  never by hand, so a crash inside the transaction cannot leave a room wedged.
  """

  import Ecto.Query

  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Repo

  @identity_lock_class 1
  @seats_lock_class 2
  @match_lock_class 3

  @doc "Serializes everything one account does across rooms. Always taken first."
  @spec identity(integer()) :: :ok
  def identity(user_id), do: advisory(@identity_lock_class, user_id)

  @doc "Serializes the seat count of one room. Only ever taken after `identity/1`."
  @spec seats(integer()) :: :ok
  def seats(session_id), do: advisory(@seats_lock_class, session_id)

  @doc "Serializes the commands that move one match. Taken alone."
  @spec match(integer()) :: :ok
  def match(session_id), do: advisory(@match_lock_class, session_id)

  @doc """
  Takes the room's row with `FOR UPDATE` and answers with it, or `nil`.

  A row lock rather than an advisory one: the callers that want it are about to
  write the row, and they want whoever else is writing it to wait rather than
  to be told to try again.
  """
  @spec session(integer()) :: GameSession.t() | nil
  def session(id) do
    GameSession |> where([s], s.id == ^id) |> lock("FOR UPDATE") |> Repo.one()
  end

  defp advisory(class, key) do
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [class, key])

    :ok
  end
end
