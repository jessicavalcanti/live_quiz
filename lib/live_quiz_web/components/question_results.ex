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
          "flex items-center gap-3 rounded-xl border p-4 text-xl font-bold",
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
            "rounded-xl border p-4",
            if(option.is_correct, do: "border-success bg-success/10", else: "border-base-300")
          ]}
        >
          <div class="flex flex-wrap items-center gap-3">
            <span
              aria-hidden="true"
              class="flex size-8 shrink-0 items-center justify-center rounded-lg bg-base-200 font-bold"
            >
              {Formatters.option_letter(option.position)}
            </span>

            <span class="min-w-0 break-words font-medium">{option.text}</span>

            <span
              :if={option.is_correct}
              class="flex shrink-0 items-center gap-1 text-sm font-semibold text-success"
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
            <span aria-hidden="true" class="h-3 flex-1 rounded-full bg-base-200">
              <span
                class={[
                  "block h-3 rounded-full transition-all",
                  if(option.is_correct, do: "bg-success", else: "bg-base-content/40")
                ]}
                style={"width: #{Formatters.answer_share(option.count, @results.answers_count)}%"}
              ></span>
            </span>

            <span class="shrink-0 text-sm tabular-nums text-base-content/70">
              {Formatters.format_answer_share(option.count, @results.answers_count)}
            </span>
          </div>
        </li>
      </ul>

      <p
        :if={@results.no_answer_count > 0}
        id="no-answer-count"
        class="text-base-content/70"
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

  defp own_result_class(%{my_answer_option_id: nil}), do: "border-warning bg-warning/10"
  defp own_result_class(%{my_answer_correct?: true}), do: "border-success bg-success/10"
  defp own_result_class(%{}), do: "border-error bg-error/10"

  # A question always freezes exactly four alternatives, so the letters never
  # run past the beginning of the alphabet.
end
