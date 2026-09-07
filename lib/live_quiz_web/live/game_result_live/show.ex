defmodule LiveQuizWeb.GameResultLive.Show do
  @moduledoc "Detailed immutable result for the authenticated participant."

  use LiveQuizWeb, :live_view

  alias LiveQuiz.Games
  alias LiveQuizWeb.Formatters

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Games.get_my_game_result(socket.assigns.current_scope, id) do
      {:ok, result} ->
        {:ok, assign(socket, page_title: "Detalhes da partida", result: result)}

      {:error, :not_found} ->
        raise Ecto.NoResultsError, queryable: LiveQuiz.Games.GameResult
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="game-result-detail" class="space-y-8">
        <.link navigate={~p"/game-results"} class="link link-primary">← Voltar para minhas partidas</.link>
        <div>
          <p class="text-sm font-semibold uppercase tracking-wider text-primary">Resultado final</p>
          <h1 class="mt-2 text-3xl font-bold">{@result.quiz_title}</h1>
          <p class="mt-2 text-base-content/70">
            Realizada em {Formatters.format_datetime(@result.inserted_at)}
          </p>
        </div>
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
        <section aria-labelledby="question-details-heading">
          <h2 id="question-details-heading" class="text-2xl font-bold">Detalhes por pergunta</h2>
          <div id="question-results" class="mt-4 space-y-4">
            <article
              :for={{position, question} <- sorted_questions(@result.question_results)}
              id={"question-result-#{position}"}
              class="rounded-box border border-base-300 p-5"
            >
              <div class="flex items-start justify-between gap-4">
                <h3 class="font-semibold">Pergunta {position}: {question["question"]}</h3>
                <span class={result_badge(question["correct"])}>{result_label(question["correct"])}</span>
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
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp metric(assigns) do
    ~H"""
    <div class="rounded-box bg-base-200 p-4">
      <p class="text-xs uppercase text-base-content/60">{@label}</p><p class="mt-1 font-bold">
        {@value}
      </p>
    </div>
    """
  end

  defp sorted_questions(results),
    do: results |> Enum.sort_by(fn {position, _} -> String.to_integer(position) end)

  defp result_label(true), do: "Correta"
  defp result_label(false), do: "Incorreta"
  defp result_label(nil), do: "Sem resposta"
  defp result_badge(true), do: "badge badge-success"
  defp result_badge(false), do: "badge badge-error"
  defp result_badge(nil), do: "badge badge-ghost"
end
