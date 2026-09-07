defmodule LiveQuiz.Games.Locks do
  @moduledoc """
  The advisory locks a room is serialized by, and the order they are taken in.

  Postgres advisory locks live in one namespace shared by the whole
  application, so every key carries a *class* saying what the rest of it
  identifies. Keeping the classes in one module is the point: two callers that
  picked the same class for different subjects would block each other for no
  reason, and two that picked different classes for the same subject would not
  block at all — the failure nobody notices until two browser tabs both win.

  ## Why one 64-bit key and not two 32-bit ones

  The two-argument form of `pg_advisory_xact_lock` takes two `int4`, and the
  ids of this application are `bigint`. Past `2_147_483_647` the id is simply
  not representable there: the call would fail, on the busiest table, long after
  anybody was still thinking about advisory locks (R45).

  So the class and the id are packed into the single `bigint` key instead: the
  class in the high bits, the id in the low #{56}. That is exact rather than
  hashed — two different subjects can never collide into the same lock — and it
  costs a bound on the id, `#{1_000} times` beyond anything a `bigserial` will
  reach in the life of this application. The bound is checked rather than
  assumed: an id past it raises here, where the message can say what happened,
  instead of wedging a room.

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

  # 56 bits for the id leaves the class in the top 8 and the whole key inside a
  # signed `bigint`. A `bigserial` reaching 2^56 would need a row inserted every
  # microsecond for two thousand years.
  @id_bits 56
  @max_id Bitwise.<<<(1, @id_bits) - 1

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

  defp advisory(class, id) when is_integer(id) and id > 0 and id <= @max_id do
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [key(class, id)])

    :ok
  end

  defp advisory(_class, id) do
    raise ArgumentError,
          "#{inspect(id)} cannot be locked: an advisory lock key holds ids from 1 to #{@max_id}"
  end

  @doc """
  The single `bigint` key a class and an id become.

  Public so a test can prove that two classes never produce the same key for
  the same id, and that the packing survives the largest id it accepts.
  """
  @spec key(pos_integer(), pos_integer()) :: pos_integer()
  def key(class, id) when is_integer(class) and is_integer(id) do
    Bitwise.<<<(class, @id_bits) + id
  end

  @doc "The largest row id an advisory lock key can hold."
  @spec max_id() :: pos_integer()
  def max_id, do: @max_id
end
