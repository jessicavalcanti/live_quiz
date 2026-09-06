defmodule LiveQuizWeb.Api.V1.GamePlayJSON do
  @moduledoc """
  Renders the execution of a match inside the `data` envelope of the API.

  A serializer and nothing else: every map it receives was built by
  `LiveQuiz.Games`, which is also where the decision of *what* a viewer may see
  was taken. This module reads no database, asks no presence and never chooses
  between the host's shape and the player's — it only renames what the context
  already settled, so the web and the API cannot disagree about the answer key.

  Two renamings are deliberate. The `?` of the Elixir keys (`last_question?`,
  `my_answer_correct?`) has no place in JSON, and `correct` becomes `is_correct`
  to read the same as the tally does.

  The answer key is **omitted** rather than sent as `null` while it is withheld
  (AD-46): a client of the API cannot tell a `null` it must not trust from an
  alternative that is simply wrong, and an absent field is the one shape that
  says nothing at all. Once the question closes — and for the host, who runs it
  — the field is there with the frozen key.
  """

  alias LiveQuiz.Games.Answer
  alias LiveQuiz.Games.GameSession

  @doc "Renders the state of the match as the viewer is allowed to see it."
  def state(%{state: state}), do: %{data: state_data(state)}

  @doc "Renders the tally of a question that has closed."
  def results(%{results: results}), do: %{data: results_data(results)}

  @doc "Renders the answer that was just recorded."
  def answer(%{answer: %Answer{} = answer, closed?: closed?}) do
    %{
      data: %{
        answer_option_id: answer.game_session_answer_option_id,
        answered_at: answer.answered_at,
        question_closed: closed?
      }
    }
  end

  @doc "Renders what a match that has just been ended adds up to."
  def summary(%{session: %GameSession{} = session, summary: summary}) do
    %{
      data: %{
        status: summary.status,
        finished_at: session.finished_at,
        question_count: summary.question_count,
        questions_played: summary.questions_played,
        answers_count: summary.answers_count,
        participants_count: summary.participants_count
      }
    }
  end

  # The host's state carries `answers_count` and the player's carries
  # `my_answer_option_id`, and which one is there is the context's decision. The
  # key is copied when it exists instead of being defaulted, so a player who has
  # not answered still gets `my_answer_option_id: null` — "nothing chosen" — and
  # never the absence that would mean "not your business".
  defp state_data(state) do
    base = %{
      status: state.status,
      question_number: state.question_number,
      question_count: state.question_count,
      question_state: state.question_state,
      question_text: state.question_text,
      ends_at: state.ends_at,
      seconds_left: state.seconds_left,
      last_question: state.last_question?,
      options: Enum.map(state.options, &state_option/1)
    }

    Enum.reduce([:answers_count, :my_answer_option_id], base, fn key, data ->
      case Map.fetch(state, key) do
        {:ok, value} -> Map.put(data, key, value)
        :error -> data
      end
    end)
  end

  defp state_option(%{correct: nil} = option), do: Map.take(option, [:id, :position, :text])

  defp state_option(%{correct: correct} = option) do
    option |> Map.take([:id, :position, :text]) |> Map.put(:is_correct, correct)
  end

  defp results_data(results) do
    %{
      position: results.position,
      question_count: results.question_count,
      question_text: results.question_text,
      answers_count: results.answers_count,
      no_answer_count: results.no_answer_count,
      participants_count: results.participants_count,
      options:
        Enum.map(results.options, &Map.take(&1, [:id, :position, :text, :is_correct, :count])),
      my_answer_option_id: results.my_answer_option_id,
      my_answer_correct: results.my_answer_correct?
    }
  end
end
