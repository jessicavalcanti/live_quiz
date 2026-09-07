defmodule LiveQuiz.Repo do
  @moduledoc """
  The repository, plus the one convention that keeps its two transaction
  functions from looking like an accident.

  Both are in use and both are right, for different shapes:

    * `transact/2` when the body already answers in `{:ok, value}` or
      `{:error, reason}` — a `with` whose every step is a repo call, say. The
      rollback is the return value, and there is nothing else to write.
    * `transaction/2` with `rollback/1` when the reason to give up is decided
      deep inside, and the value on success is not wrapped. Most of
      `LiveQuiz.Games` is this: a lock is taken, a guard refuses, and the
      refusal has to travel out as `{:error, :stale}` from three levels down.

  Reaching for `transaction/2` when the body already answers in tuples only
  adds a `Repo.rollback/1` that says what the tuple already said.
  """

  use Ecto.Repo,
    otp_app: :live_quiz,
    adapter: Ecto.Adapters.Postgres
end
