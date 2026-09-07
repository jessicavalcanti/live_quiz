defmodule LiveQuiz.Repo.Migrations.IndexTheHistoryOrderings do
  @moduledoc """
  Indexes shaped like the queries the histories actually run.

  Both listings filter by owner and order by recency, and neither index covered
  the ordering: `game_results_user_id_index` finds a person's results and then
  Postgres sorts all of them to hand back twenty; `game_sessions` had nothing at
  all for "matches this account hosted, newest first" (R37).

  The order of the columns is the order of the query — owner first, because it
  is the equality, then the sort keys in the direction they are read. The id is
  the tie-break the paginations already order by, so the index answers the whole
  `ORDER BY` rather than most of it.

  These replace nothing: the single-column indexes stay, because the foreign
  keys still use them for cascades and for the counts.
  """

  use Ecto.Migration

  def change do
    create index(:game_results, [:user_id, "inserted_at DESC", "id DESC"],
             name: :game_results_user_recency_index
           )

    create index(:game_sessions, [:host_id, "finished_at DESC", "id DESC"],
             where: "status = 'finished'",
             name: :game_sessions_host_finished_recency_index
           )
  end
end
