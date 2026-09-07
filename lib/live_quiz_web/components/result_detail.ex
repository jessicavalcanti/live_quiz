defmodule LiveQuizWeb.ResultDetail do
  @moduledoc """
  The immutable result of one participation, shown to whoever may see it.

  Two screens show this: the person looking at their own match, and the host
  looking at one participant's. They differ in what leads into the block — a
  back link, a title, a subtitle — and in nothing else. Both were rendering
  their own copy of the metrics grid, their own ordering by position and their
  own badge for right/wrong/unanswered (R41).

  Duplication of a card is a small cost; duplication of the *rules* inside it
  is not. "Sem resposta" and "Incorreta" are different things to say to a
  person, and two copies of that distinction are two places for it to drift —
  which is the same failure mode as counting a correct answer worth zero points
  as wrong (R09), one screen up.

  The `id` prefix is what keeps the two pages addressable apart, so a test or a
  stylesheet that names one does not reach the other.
  """

  use Phoenix.Component

  alias LiveQuizWeb.Formatters

  attr :result, :map, required: true
  attr :id, :string, required: true
  attr :heading, :string, required: true
  attr :class, :string, default: nil

  slot :header, required: true

  @doc """
  Renders the header given, the five metrics and the answer to every question.
  """
  def result_detail(assigns) do
    ~H"""
    <div id={@id} class={["space-y-8", @class]}>
      {render_slot(@header)}

      <.metrics result={@result} />

      <section aria-labelledby={"#{@id}-questions-heading"}>
        <h2 id={"#{@id}-questions-heading"} class="text-2xl font-bold">{@heading}</h2>

        <div id={"#{@id}-questions"} class="mt-4 space-y-4">
          <article
            :for={{position, question} <- by_position(@result.question_results)}
            id={"#{@id}-question-#{position}"}
            class="rounded-box border border-base-300 p-5"
          >
            <div class="flex items-start justify-between gap-4">
              <h3 class="font-semibold">Pergunta {position}: {question["question"]}</h3>
              <span class={badge(question["correct"])}>{label(question["correct"])}</span>
            </div>

            <p class="mt-3 text-sm text-base-content/70">
              Resposta: {question["answer"] || "Não respondida"}
            </p>

            <p class="mt-1 text-sm text-base-content/70">
              Tempo: {Formatters.format_response_time(question["response_time_ms"] || 0)}
            </p>
          </article>
        </div>
      </section>
    </div>
    """
  end

  attr :result, :map, required: true

  defp metrics(assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-5">
      <.metric label="Pontuação" value={Formatters.format_score(@result.score)} />
      <.metric label="Posição" value={"##{@result.final_position}"} />
      <.metric label="Acertos" value={Formatters.format_correct_answers(@result.correct_answers)} />
      <.metric label="Respondidas" value={"#{@result.answered_questions}"} />
      <.metric
        label="Tempo médio"
        value={Formatters.format_response_time(@result.average_response_time_ms)}
      />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp metric(assigns) do
    ~H"""
    <div class="rounded-box bg-base-200 p-4">
      <p class="text-xs uppercase text-base-content/60">{@label}</p>
      <p class="mt-1 font-bold">{@value}</p>
    </div>
    """
  end

  # The keys are the positions, written as strings by the JSON column, so
  # sorting them as strings would put question 10 between 1 and 2.
  defp by_position(results) do
    Enum.sort_by(results, fn {position, _question} -> String.to_integer(position) end)
  end

  # Three answers, not two: not answering is not the same as answering wrong,
  # and the person reading this is the one who did one or the other.
  defp label(true), do: "Correta"
  defp label(false), do: "Incorreta"
  defp label(nil), do: "Sem resposta"

  defp badge(true), do: "badge badge-success"
  defp badge(false), do: "badge badge-error"
  defp badge(nil), do: "badge badge-ghost"
end
