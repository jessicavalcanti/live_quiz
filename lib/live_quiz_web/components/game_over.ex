defmodule LiveQuizWeb.GameOver do
  @moduledoc """
  The screen that closes a room, whichever way it ended.

  Finishing, cancelling and expiring are three different pieces of news and one
  single screen: the same block says what happened, how much of the match was
  actually played and where to go from here, so the phase 2 endings and the
  phase 3 one never drift apart in two copies of the same markup.

  It is deliberately simple (F3-10): the title, how many questions were applied
  and a way out. There is no score, no position and no ranking here — those are
  phase 4, and they will be computed on top of the very answers this phase
  persisted, not sneaked into this screen ahead of time.

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
