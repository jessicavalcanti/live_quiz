defmodule LiveQuizWeb.GameSessionLive.MatchAssigns do
  @moduledoc """
  The reads the host screen and the player screen make in common.

  Both screens draw the same match from the same context, and `LiveQuiz.Games`
  already takes either identity — a `Scope` or a `Participant` — for every one
  of these reads. What the two LiveViews had was the same three loaders written
  twice, differing only in which assign held the viewer.

  Keeping them apart had already cost something: the host read the summary with
  `{:ok, summary} = Games.game_summary(...)`, so a refusal the player screen
  handled as "nothing to show" would have crashed the host's. The refusals are
  handled here once, and each screen is left with the one line that is really
  different between them — who it is watching as.

  A refusal is never an error to render. `question_results/3` says no while the
  question is still open (AD-46), which is also what happens in the seconds
  between a deadline passing on screen and the timer closing the question;
  `current_ranking/2` and `game_summary/2` say no to somebody who may not watch.
  In all three cases the assign goes to `nil` and the screen shows what it shows
  when it has nothing yet.
  """

  import Phoenix.Component, only: [assign: 3]

  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession

  @typedoc "Whichever identity this screen is watching the match as."
  @type viewer :: LiveQuiz.Accounts.Scope.t() | LiveQuiz.Games.Participant.t()

  @doc """
  Assigns `:results` with the tally of the question that has just been revealed.

  Anything but a closed question assigns `nil`: there is no answer key to draw
  before the reveal, and asking for one is what the context refuses.
  """
  @spec assign_results(Phoenix.LiveView.Socket.t(), viewer(), map()) ::
          Phoenix.LiveView.Socket.t()
  def assign_results(socket, viewer, %{question_state: :closed, question_number: position}) do
    case Games.question_results(socket.assigns.session, position, viewer) do
      {:ok, results} -> assign(socket, :results, results)
      {:error, _nothing_to_reveal} -> assign(socket, :results, nil)
    end
  end

  def assign_results(socket, _viewer, _open_or_pending), do: assign(socket, :results, nil)

  @doc """
  Assigns `:ranking`, either for a question that has just been revealed or for
  a match that is over.

  The two moments a ranking is shown are the only two it is read in, and they
  arrive here as the two things that describe them: the state of the match for
  the first, the room itself for the second.
  """
  @spec assign_ranking(Phoenix.LiveView.Socket.t(), viewer(), map() | GameSession.t()) ::
          Phoenix.LiveView.Socket.t()
  def assign_ranking(socket, viewer, %GameSession{status: :finished}),
    do: read_ranking(socket, viewer)

  def assign_ranking(socket, viewer, %{question_state: :closed}),
    do: read_ranking(socket, viewer)

  def assign_ranking(socket, _viewer, _nothing_to_rank), do: assign(socket, :ranking, nil)

  @doc """
  Assigns `:summary` with what the match added up to, once the room is over.

  A room still live assigns `nil` without asking: no screen shows the summary
  while the match is running, and reading it on every event would cost a query
  for a number nobody is looking at.
  """
  @spec assign_summary(Phoenix.LiveView.Socket.t(), viewer()) :: Phoenix.LiveView.Socket.t()
  def assign_summary(socket, viewer) do
    session = socket.assigns.session

    if GameSession.active?(session) do
      assign(socket, :summary, nil)
    else
      case Games.game_summary(session, viewer) do
        {:ok, summary} -> assign(socket, :summary, summary)
        {:error, :unauthorized} -> assign(socket, :summary, nil)
      end
    end
  end

  defp read_ranking(socket, viewer) do
    case Games.current_ranking(socket.assigns.session, viewer) do
      {:ok, ranking} -> assign(socket, :ranking, ranking)
      {:error, :unauthorized} -> assign(socket, :ranking, nil)
    end
  end
end
