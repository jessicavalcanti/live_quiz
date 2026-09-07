defmodule LiveQuizWeb.GameOver do
  @moduledoc """
  The screen that closes a room, whichever way it ended.

  Finishing, cancelling and expiring are three different pieces of news and one
  single screen: the same block says what happened, how much of the match was
  actually played and where to go from here, so the phase 2 endings and the
  phase 3 one never drift apart in two copies of the same markup.

  It is deliberately simple (F3-10): the title, how many questions were applied
  and a way out. There is no score, no position and no ranking here — those are
  phase 4, and when a finished result is available this component receives the
  persisted ranking and immutable participant snapshot from `Games`.

  Who is reading changes three things and only three: the wording — the host
  cancelled the room, the participant had it cancelled on them — the way out,
  and the heading level, since the host is reading this under the title of the
  match while for the participant this *is* the page. Everything else, the
  ending included, is the same for everybody.

  `summary` comes from `LiveQuiz.Games.game_summary/2` and may be `nil`: a room
  cancelled in the lobby played nothing, and whoever arrives without a
  participation to read has nothing to be told about it. When it is there, the
  line is drawn only for a match that got past the first question.
  """

  use LiveQuizWeb, :html

  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuizWeb.Formatters

  attr :session, GameSession, required: true
  attr :summary, :map, default: nil, doc: "de `LiveQuiz.Games.game_summary/2`"
  attr :reason, :atom, values: [:finished, :cancelled, :expired], required: true
  attr :viewer, :atom, values: [:host, :player], required: true
  attr :ranking, :list, default: nil
  attr :result, :map, default: nil

  @doc """
  Renders the ending of a match for the host or for whoever played it.
  """
  def game_over(assigns) do
    ~H"""
    <section id="room-closed" role="status" class="py-16 text-center">
      <.dynamic_tag tag_name={heading_tag(@viewer)} class="text-3xl font-bold">
        {title(@reason, @viewer)}
      </.dynamic_tag>

      <p id="room-closed-quiz" class="mt-2 text-base-content/70">{@session.quiz_title}</p>

      <p class="mt-3 text-base-content/70">{message(@reason, @viewer)}</p>

      <p :if={played?(@summary)} id="questions-played" class="mt-3 text-lg">
        {Formatters.format_questions_played(@summary.questions_played, @summary.question_count)}
      </p>

      <%= if @reason == :finished and @ranking do %>
        <LiveQuizWeb.Ranking.ranking
          ranking={@ranking}
          current_participant_id={result_participant_id(@result)}
          title="Resultado final"
        />
      <% end %>

      <div
        :if={@reason == :finished && @result}
        id="own-result-summary"
        class="mt-6 space-y-3 rounded-2xl border border-primary bg-primary/5 p-5 text-left"
      >
        <h2 class="text-xl font-bold">Seu resultado</h2>
        <p id="own-final-position">
          Você terminou em <strong>{@result.final_position}º lugar</strong>
        </p>
        <p id="own-final-score"><strong>{Formatters.format_score(@result.score)}</strong></p>
        <dl class="grid grid-cols-2 gap-3 text-sm sm:grid-cols-4">
          <div>
            <dt class="text-base-content/70">Acertos</dt><dd class="font-bold">
              {@result.correct_answers}
            </dd>
          </div>
          <div>
            <dt class="text-base-content/70">Erros</dt><dd class="font-bold">
              {@result.incorrect_answers}
            </dd>
          </div>
          <div>
            <dt class="text-base-content/70">Sem resposta</dt><dd class="font-bold">
              {@result.unanswered_questions}
            </dd>
          </div>
          <div>
            <dt class="text-base-content/70">Tempo médio</dt><dd class="font-bold">
              {Formatters.format_response_time(@result.average_response_time_ms)}
            </dd>
          </div>
        </dl>
      </div>

      <div class="mt-6">
        <.button
          :if={@viewer == :host}
          id="back-to-quizzes"
          variant="primary"
          navigate={~p"/quizzes"}
        >
          Voltar para Meus quizzes
        </.button>

        <.button :if={@viewer == :player} id="back-to-join" variant="primary" navigate={~p"/join"}>
          Entrar em outra sala
        </.button>
      </div>
    </section>
    """
  end

  # A match cancelled before the first question played nothing, and "0 de 10"
  # is a number that only asks to be interpreted.
  defp played?(%{questions_played: played}) when played > 0, do: true
  defp played?(_nothing_played), do: false

  defp result_participant_id(%{participant_id: participant_id}), do: participant_id
  defp result_participant_id(_result), do: nil

  defp heading_tag(:host), do: "h2"
  defp heading_tag(:player), do: "h1"

  defp title(:cancelled, :host), do: "Sala cancelada"
  defp title(:cancelled, :player), do: "Sala cancelada pelo host"
  defp title(:expired, :host), do: "Sala encerrada por ausência"
  defp title(:expired, :player), do: "Sala encerrada por ausência do host"
  defp title(:finished, _viewer), do: "Partida finalizada"

  defp message(:cancelled, :host),
    do: "Você cancelou esta sala e os participantes foram avisados. Abra outra quando quiser."

  defp message(:cancelled, :player),
    do: "O host encerrou esta sala. Nada deu errado do seu lado: é só entrar em outra."

  defp message(:expired, :host),
    do:
      "A sala ficou sem host por mais de #{absence_minutes()} minutos e foi encerrada. " <>
        "Abra outra sala para jogar de novo."

  defp message(:expired, :player),
    do: "O host ficou fora tempo demais e a sala foi encerrada. Você pode entrar em outra."

  defp message(:finished, :host),
    do: "Esta partida chegou ao fim. Abra outra sala para jogar de novo."

  defp message(:finished, :player),
    do: "Esta partida chegou ao fim. Você pode entrar em outra sala."

  defp absence_minutes, do: div(Games.host_absence_timeout(), 60)
end
