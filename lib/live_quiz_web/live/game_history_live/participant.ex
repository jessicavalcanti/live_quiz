defmodule LiveQuizWeb.GameHistoryLive.Participant do
  @moduledoc "Immutable answer details for one participant, visible to the host."

  use LiveQuizWeb, :live_view

  alias LiveQuiz.Games
  alias LiveQuizWeb.Formatters

  @impl true
  def mount(%{"result_id" => id, "id" => session_id}, _session, socket) do
    with {:ok, result} <- Games.get_host_game_result(socket.assigns.current_scope, id),
         true <- to_string(result.game_session_id) == session_id do
      {:ok, assign(socket, page_title: "Detalhes do participante", result: result)}
    else
      _ -> raise Ecto.NoResultsError, queryable: LiveQuiz.Games.GameResult
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="host-participant-result" class="space-y-8">
        <.link navigate={~p"/game-history/#{@result.game_session_id}"} class="link link-primary">← Voltar para o ranking</.link>
        <div>
          <p class="text-sm font-semibold uppercase tracking-wider text-primary">
            Desempenho individual
          </p><h1 class="mt-2 text-3xl font-bold">{@result.nickname}</h1><p class="mt-2 text-base-content/70">
            {@result.quiz_title}
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
        <section aria-labelledby="host-question-details-heading">
          <h2 id="host-question-details-heading" class="text-2xl font-bold">
            Respostas por pergunta
          </h2><div id="host-question-results" class="mt-4 space-y-4">
            <article
              :for={{position, question} <- sorted_questions(@result.question_results)}
              id={"host-question-result-#{position}"}
              class="rounded-box border border-base-300 p-5"
            >
              <div class="flex items-start justify-between gap-4">
                <h3 class="font-semibold">Pergunta {position}: {question["question"]}</h3><span class={
                  badge(question["correct"])
                }>{label(question["correct"])}</span>
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
      <p class="text-xs uppercase text-base-content/60">{@label}</p>
      <p class="mt-1 font-bold">{@value}</p>
    </div>
    """
  end

  defp sorted_questions(results),
    do: Enum.sort_by(results, fn {position, _} -> String.to_integer(position) end)

  defp label(true), do: "Correta"
  defp label(false), do: "Incorreta"
  defp label(nil), do: "Sem resposta"
  defp badge(true), do: "badge badge-success"
  defp badge(false), do: "badge badge-error"
  defp badge(nil), do: "badge badge-ghost"
end
