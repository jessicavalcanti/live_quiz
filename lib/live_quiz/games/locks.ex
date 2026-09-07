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

  **Order matters, and there is exactly one:**

      identity  →  match  →  seats

  Every command that changes a room, its seats or a participation takes the
  locks it needs in that order and skips the ones it does not. Two commands
  taking the same locks in opposite orders is a deadlock nobody sees until a
  room wedges under load, so the order is stated here rather than left to be
  inferred from each call site.

  | Command | Takes |
  |---|---|
  | entering, coming back | identity, seats |
  | opening a room | identity (plus the quiz row) |
  | advancing, closing, answering | match |
  | finishing, cancelling, expiring | match, seats |

  Ending a room takes the seats lock as well as the match one, which is what
  makes a join already under way finish *before* the room closes — and be
  released with everybody else — or wait and find the room terminal. Without
  it a participation could be inserted after the release ran, leaving somebody
  tied to a room that is over.

  A lock only serializes; it decides nothing. Every command re-reads the room
  under the lock and re-checks what it validated before taking it: the read
  that authorized the command happened earlier, and by the time the lock is
  granted the winner has already changed the answer.

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

  @doc "Serializes the seat count of one room. Always taken last."
  @spec seats(integer()) :: :ok
  def seats(session_id), do: advisory(@seats_lock_class, session_id)

  @doc "Serializes the commands that move one match. Taken after identity, before seats."
  @spec match(integer()) :: :ok
  def match(session_id), do: advisory(@match_lock_class, session_id)

  @doc """
  Takes both room locks in the order this module fixes, for a transition that
  ends a room: the match stops moving and the seats stop being handed out.
  """
  @spec room(integer()) :: :ok
  def room(session_id) do
    match(session_id)
    seats(session_id)
  end

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
