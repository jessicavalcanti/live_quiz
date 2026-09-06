defmodule LiveQuizWeb.Ranking do
  @moduledoc """
  Renders the deterministic ranking of a match.

  The ordering and positions are supplied by `LiveQuiz.Games`; this component
  only presents the snapshot and marks the viewer's own row when there is one.
  """

  use LiveQuizWeb, :html

  alias LiveQuizWeb.Formatters

  attr :ranking, :list, required: true
  attr :current_participant_id, :integer, default: nil
  attr :title, :string, default: "Ranking"

  @doc "Renders a ranking that is announced as a live status update."
  def ranking(assigns) do
    ~H"""
    <section id="ranking" aria-live="polite" aria-atomic="false" class="space-y-4">
      <h2 id="ranking-title" class="text-2xl font-bold">{@title}</h2>

      <ol id="ranking-list" class="space-y-3" aria-labelledby="ranking-title">
        <li
          :for={entry <- @ranking}
          id={"ranking-participant-#{entry.participant_id}"}
          class={[
            "flex items-center gap-3 rounded-xl border p-4 transition",
            if(entry.participant_id == @current_participant_id,
              do: "border-primary bg-primary/10 ring-1 ring-primary",
              else: "border-base-300"
            )
          ]}
        >
          <span
            id={"ranking-position-#{entry.participant_id}"}
            class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-base-200 font-black tabular-nums"
            aria-label={"posição #{entry.position}"}
          >
            {entry.position}
          </span>

          <span class="min-w-0 flex-1 break-words font-semibold">
            {entry.nickname}
            <span
              :if={entry.participant_id == @current_participant_id}
              id="own-ranking"
              class="ml-1 text-primary"
            >
              (você)
            </span>
          </span>

          <span class="shrink-0 text-right">
            <strong id={"ranking-score-#{entry.participant_id}"} class="block tabular-nums">
              {Formatters.format_score(entry.score)}
            </strong>
            <span class="text-xs text-base-content/70">
              {Formatters.format_correct_answers(entry.correct_answers)}
            </span>
          </span>
        </li>
      </ol>
    </section>
    """
  end
end
