defmodule LiveQuizWeb.QuestionResults do
  @moduledoc """
  The reveal of a question that has closed: answer key, distribution, absences.

  It is the most fun moment of the match — which one was right and how many
  people fell for each alternative — and it is the same reading for the host and
  for whoever played, which is why both screens render this one block instead of
  each writing its own. The only difference is the line at the top: a
  participant also learns what they picked and whether it was right, and the
  host, who does not play, never sees a personal verdict.

  Everything shown comes from `LiveQuiz.Games.question_results/3` and nothing is
  computed here beyond turning a count into a width: the answer key is the
  frozen one (AD-36), an alternative nobody chose arrives with `count: 0` and is
  listed all the same (AD-43), and "sem resposta" is a difference the context
  hands over, never a row of the list.

  The share is taken over who answered, never over who was in the room: putting
  the absences in the denominator would make the most voted alternative look
  less voted than it was. A question nobody answered divides by zero, which is
  why the share comes from `LiveQuizWeb.Formatters.answer_share/2` and answers
  zero instead of raising.

  The bar is CSS and nothing else — four values never justify a charting
  library — and it is `aria-hidden` on purpose: a width says nothing out loud,
  so the count and the percentage are written next to it, as text.
  """

  use LiveQuizWeb, :html

  alias LiveQuizWeb.Formatters

  attr :results, :map, required: true, doc: "de `LiveQuiz.Games.question_results/3`"
  attr :viewer, :atom, values: [:host, :player], required: true

  @doc """
  Renders the tally of a closed question for the host or for whoever played.
  """
  def question_results(assigns) do
    ~H"""
    <section id="question-results" class="mt-6 space-y-5 text-left">
      <p
        :if={@viewer == :player}
        id="own-result"
        class={[
          "flex items-center gap-3 rounded-lg border p-4 text-lg font-semibold",
          own_result_class(@results)
        ]}
      >
        <.icon name={own_result_icon(@results)} class="size-7 shrink-0" />
        {own_result_message(@results)}
      </p>

      <ul id="results-distribution" class="space-y-3">
        <li
          :for={option <- @results.options}
          id={"result-option-#{option.id}"}
          class={[
            "rounded-lg border p-4",
            if(option.is_correct,
              do: "border-success/50 bg-success/10",
              else: "border-border bg-card"
            )
          ]}
        >
          <div class="flex flex-wrap items-center gap-3">
            <span
              aria-hidden="true"
              class={[
                "flex size-8 shrink-0 items-center justify-center rounded-md font-semibold",
                if(option.is_correct,
                  do: "bg-success text-success-foreground",
                  else: "bg-muted text-muted-foreground"
                )
              ]}
            >
              {Formatters.option_letter(option.position)}
            </span>

            <span class="min-w-0 font-medium break-words">{option.text}</span>

            <span
              :if={option.is_correct}
              class="flex shrink-0 items-center gap-1 text-sm font-semibold text-success-strong"
            >
              <.icon name="hero-check-circle" class="size-5" /> Resposta correta
            </span>

            <span
              :if={own_choice?(assigns, option)}
              class="flex shrink-0 items-center gap-1 text-sm font-semibold text-primary"
            >
              sua resposta
            </span>
          </div>

          <div class="mt-3 flex items-center gap-3">
            <%!-- A barra é só desenho: o valor que ela representa está escrito ao
            lado, porque uma largura em CSS não é lida por ninguém. --%>
            <span aria-hidden="true" class="h-2 flex-1 rounded-full bg-muted">
              <span
                class={[
                  "block h-2 rounded-full transition-all",
                  if(option.is_correct, do: "bg-success", else: "bg-muted-foreground/50")
                ]}
                style={"width: #{Formatters.answer_share(option.count, @results.answers_count)}%"}
              ></span>
            </span>

            <span class="shrink-0 text-sm tabular-nums text-muted-foreground">
              {Formatters.format_answer_share(option.count, @results.answers_count)}
            </span>
          </div>
        </li>
      </ul>

      <p
        :if={@results.no_answer_count > 0}
        id="no-answer-count"
        class="text-sm text-muted-foreground"
      >
        {Formatters.format_absences(@results.no_answer_count)}
      </p>
    </section>
    """
  end

  # The host does not play, so nothing on this block is ever about them: the
  # personal verdict and the mark on the chosen alternative exist for whoever
  # answered and for nobody else.
  defp own_choice?(%{viewer: :player, results: results}, option),
    do: results.my_answer_option_id == option.id

  defp own_choice?(_host, _option), do: false

  defp own_result_message(%{my_answer_option_id: nil}), do: "Você não respondeu"
  defp own_result_message(%{my_answer_correct?: true}), do: "Você acertou!"
  defp own_result_message(%{}), do: "Você errou"

  defp own_result_icon(%{my_answer_option_id: nil}), do: "hero-minus-circle"
  defp own_result_icon(%{my_answer_correct?: true}), do: "hero-check-circle"
  defp own_result_icon(%{}), do: "hero-x-circle"

  defp own_result_class(%{my_answer_option_id: nil}),
    do: "border-warning/50 bg-warning/10 text-warning-strong"

  defp own_result_class(%{my_answer_correct?: true}),
    do: "border-success/50 bg-success/10 text-success-strong"

  defp own_result_class(%{}), do: "border-destructive/50 bg-destructive/10 text-destructive"

  # A question always freezes exactly four alternatives, so the letters never
  # run past the beginning of the alphabet.
end
