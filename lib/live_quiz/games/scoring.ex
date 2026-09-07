defmodule LiveQuiz.Games.Scoring do
  @moduledoc """
  What a closed question is worth, and the standing it produces.

  A correct answer is worth up to a thousand points, in proportion to the clock
  it had left when it arrived; a wrong one and a missing one are worth nothing.
  The arithmetic reads the frozen answer key and the server's own timestamps —
  never anything the client sent — so the only thing a fast connection buys is
  arriving earlier.

  Consolidating a question is idempotent and safe to lose a race on. It runs
  under the match's advisory lock and the question's row lock, and the question
  carries a `scored_at` marker: the call that gets there first does the writing
  and publishes `{:ranking_updated, ranking}`, and every call after it reads the
  same standing back without counting anything twice. That matters because the
  three ways a question can close — the host, the deadline, everybody having
  answered — can happen in the same instant.

  The room's metrics are written in two statements rather than one per person.
  Twenty-five participations used to mean up to fifty `UPDATE`s serialized
  inside the transaction that holds the match lock, with the whole room watching
  a screen that had not moved yet.

  Nothing here decides who may *read* a ranking; that is
  `LiveQuiz.Games.Access`.
  """

  import Ecto.Query

  require Logger

  alias LiveQuiz.Games.Access
  alias LiveQuiz.Games.Answer
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.GameSessionQuestion
  alias LiveQuiz.Games.Locks
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Games.Topic
  alias LiveQuiz.Repo

  @doc """
  Calculates an answer's score from the frozen answer key and server timestamps.

  Correct answers are worth up to 1000 points, proportional to the time left
  when they arrived. Missing and incorrect answers are worth zero.
  """
  @spec calculate_answer_score(Answer.t() | nil, GameSessionQuestion.t(), GameSession.t()) ::
          non_neg_integer()
  def calculate_answer_score(nil, %GameSessionQuestion{}, %GameSession{}), do: 0

  def calculate_answer_score(
        %Answer{} = answer,
        %GameSessionQuestion{answer_options: options},
        %GameSession{question_duration_seconds: duration} = session
      )
      when is_list(options) and is_integer(duration) and duration > 0 do
    option = Enum.find(options, &(&1.id == answer.game_session_answer_option_id))

    if option && option.is_correct do
      elapsed_ms = elapsed_time_ms(answer.answered_at, session.current_question_started_at)
      remaining_ms = max(duration * 1_000 - elapsed_ms, 0)

      # A thousand points spread over the duration: the whole clock left is
      # `duration * 1_000`ms, so each millisecond is worth `1 / duration` of a
      # point. `elapsed_time_ms/2` already clamps at zero, so this cannot come
      # out above a thousand and does not need to be capped.
      div(remaining_ms, duration)
    else
      0
    end
  end

  defp elapsed_time_ms(%DateTime{} = answered_at, %DateTime{} = started_at) do
    max(DateTime.diff(answered_at, started_at, :millisecond), 0)
  end

  defp score_question(session_id, question_position) do
    Repo.transaction(fn ->
      Locks.match(session_id)

      session = Locks.session(session_id)

      case session do
        nil -> Repo.rollback(:not_found)
        %GameSession{} = current -> score_locked_question(current, session_id, question_position)
      end
    end)
  end

  defp score_locked_question(session, session_id, question_position) do
    with {:ok, running} <- GameSession.ensure_running(session),
         :ok <- GameSession.ensure_question_settled(running, question_position),
         {:ok, question} <- lock_snapshot_question(session_id, question_position) do
      answers = answers_for_question(question.id)
      participants = participants_for_scoring(session_id)

      case question.scored_at do
        %DateTime{} ->
          %{session: running, ranking_data: ranking_data(participants), scored?: false}

        nil ->
          scores = score_participants(participants, answers, question, running)
          mark_question_scored(question)

          %{session: running, ranking_data: scores, scored?: true}
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_snapshot_question(session_id, position) do
    GameSessionQuestion
    |> where([q], q.game_session_id == ^session_id and q.position == ^position)
    |> lock("FOR UPDATE")
    |> preload(:answer_options)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      question -> {:ok, question}
    end
  end

  defp answers_for_question(question_id) do
    Answer
    |> where([a], a.game_session_question_id == ^question_id)
    |> preload(:game_session_answer_option)
    |> Repo.all()
    |> Map.new(&{&1.participant_id, &1})
  end

  defp participants_for_scoring(session_id) do
    Participant
    |> where([p], p.game_session_id == ^session_id)
    |> order_by([p], asc: p.id)
    |> Repo.all()
  end

  # Twenty-five people answer a question, and consolidating them used to cost up
  # to fifty statements — one `UPDATE` per participation plus one per answer —
  # all of them serialized inside the transaction that holds the match lock,
  # while the whole room stares at the screen waiting for the reveal. The
  # arithmetic is the same; what changed is that it is written in two
  # statements, one per table, with the rows travelling as arrays.
  defp score_participants(participants, answers, question, session) do
    scored =
      Enum.map(participants, fn participant ->
        answer = Map.get(answers, participant.id)
        score = calculate_answer_score(answer, question, session)
        answered? = not is_nil(answer)
        correct? = answered? and score > 0
        response_time = response_time_ms(answer, session.current_question_started_at)

        %{
          participant: %{
            participant
            | score: participant.score + score,
              correct_answers: participant.correct_answers + if(correct?, do: 1, else: 0),
              incorrect_answers:
                participant.incorrect_answers + if(answered? and not correct?, do: 1, else: 0),
              total_response_time_ms: participant.total_response_time_ms + response_time
          },
          answer: answer,
          response_time: response_time
        }
      end)

    scored |> Enum.map(& &1.participant) |> write_participant_metrics()
    write_response_times(scored)

    scored
    |> Enum.map(&participant_ranking_data(&1.participant))
    |> Enum.sort_by(
      &{-&1.score, -&1.correct_answers, &1.total_response_time_ms, &1.participant_id}
    )
    |> Enum.with_index(1)
    |> Enum.map(fn {participant, position} -> Map.put(participant, :position, position) end)
  end

  defp write_participant_metrics([]), do: :ok

  defp write_participant_metrics(participants) do
    Repo.query!(
      """
      UPDATE participants AS p
         SET score = v.score,
             correct_answers = v.correct_answers,
             incorrect_answers = v.incorrect_answers,
             total_response_time_ms = v.total_response_time_ms,
             updated_at = $6
        FROM unnest($1::bigint[], $2::integer[], $3::integer[], $4::integer[], $5::integer[])
             AS v(id, score, correct_answers, incorrect_answers, total_response_time_ms)
       WHERE p.id = v.id
      """,
      [
        Enum.map(participants, & &1.id),
        Enum.map(participants, & &1.score),
        Enum.map(participants, & &1.correct_answers),
        Enum.map(participants, & &1.incorrect_answers),
        Enum.map(participants, & &1.total_response_time_ms),
        DateTime.utc_now(:second)
      ]
    )

    :ok
  end

  defp write_response_times(scored) do
    answered = Enum.filter(scored, &(not is_nil(&1.answer)))

    if answered != [] do
      Repo.query!(
        """
        UPDATE answers AS a
           SET response_time_ms = v.response_time_ms
          FROM unnest($1::bigint[], $2::integer[]) AS v(id, response_time_ms)
         WHERE a.id = v.id
        """,
        [
          Enum.map(answered, & &1.answer.id),
          Enum.map(answered, & &1.response_time)
        ]
      )
    end

    :ok
  end

  defp response_time_ms(nil, _started_at), do: 0

  defp response_time_ms(%Answer{answered_at: answered_at}, %DateTime{} = started_at) do
    elapsed_time_ms(answered_at, started_at)
  end

  defp mark_question_scored(%GameSessionQuestion{id: id}) do
    {1, _} =
      Repo.update_all(
        from(q in GameSessionQuestion, where: q.id == ^id and is_nil(q.scored_at)),
        set: [scored_at: DateTime.utc_now()]
      )

    :ok
  end

  defp ranking_data(participants) do
    participants
    |> Enum.map(&participant_ranking_data/1)
    |> Enum.sort_by(
      &{-&1.score, -&1.correct_answers, &1.total_response_time_ms, &1.participant_id}
    )
    |> Enum.with_index(1)
    |> Enum.map(fn {participant, position} -> Map.put(participant, :position, position) end)
  end

  @doc """
  Every participation of a match in competition order.

  Score first, then correct answers, then the total time taken, then the order
  they joined in — the same order the ranking is shown in and the one the final
  positions are frozen from, so a screen and a stored result cannot disagree
  about who came second.
  """
  @spec ranking_participants(integer()) :: [Participant.t()]
  def ranking_participants(session_id) do
    Participant
    |> where([p], p.game_session_id == ^session_id)
    |> order_by([p],
      desc: p.score,
      desc: p.correct_answers,
      asc: p.total_response_time_ms,
      asc: p.id
    )
    |> Repo.all()
  end

  defp participant_ranking_data(participant) do
    %{
      participant_id: participant.id,
      nickname: participant.nickname,
      score: participant.score,
      correct_answers: participant.correct_answers,
      incorrect_answers: participant.incorrect_answers,
      total_response_time_ms: participant.total_response_time_ms
    }
  end

  defp participant_ranking_data(participant, position) do
    participant
    |> participant_ranking_data()
    |> Map.put(:position, position)
  end

  @doc """
  Consolidates every participant's last answer for a closed question.

  A persisted marker, protected by the match and question row locks, makes
  repeated and concurrent calls return the same ranking without duplicating
  participant metrics. `{:ranking_updated, ranking}` is published only after
  commit, and only by the call that actually did the scoring — the ones that
  arrive second read the same ranking back without announcing it again.

  This is the only way a question is scored. Closing by the host, by the
  deadline and by everybody having answered all end here, which is what keeps
  the three of them from disagreeing about what the room is told.
  """
  @spec score_closed_question(GameSession.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, :question_open | :not_found | :invalid_status}
  def score_closed_question(%GameSession{id: session_id}, question_position)
      when is_integer(question_position) and question_position > 0 do
    case score_question(session_id, question_position) do
      {:ok, %{ranking_data: ranking_data, scored?: true}} ->
        publish_ranking(session_id, ranking_data)
        {:ok, ranking_data}

      {:ok, %{ranking_data: ranking_data, scored?: false}} ->
        {:ok, ranking_data}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The three ways a question closes all pass through here with the position the
  # room is sitting on. A failure is logged rather than raised: the question is
  # already closed and the reveal already announced, and a match must not stop
  # because the tally could not be written.
  @doc """
  Scores the question the match is sitting on, logging rather than raising.

  The three ways a question closes call this. A failure is not allowed to stop
  a match: the question is already closed and the reveal already announced, and
  a tally that could not be written is worth a log, not a crash in the middle of
  a game.
  """
  @spec score_and_publish_ranking(GameSession.t()) :: :ok
  def score_and_publish_ranking(%GameSession{current_question_position: position} = session) do
    case score_closed_question(session, position) do
      {:ok, _ranking} -> :ok
      {:error, reason} -> Logger.warning("could not score closed question: #{inspect(reason)}")
    end
  end

  @doc """
  Returns the current ranking of a match to its host or a participant.

  The query orders every participant by the competition rules, then assigns a
  sequential position in that same order. A participant remains visible after
  disconnecting because ranking is based on persisted metrics, not presence.
  """
  @spec current_ranking(GameSession.t(), Scope.t() | Participant.t()) ::
          {:ok, [map()]} | {:error, :unauthorized}
  def current_ranking(%GameSession{} = session, viewer) do
    current = Repo.get(GameSession, session.id) || session

    if Access.may_watch?(current, viewer) do
      current.id
      |> ranking_participants()
      |> Enum.with_index(1)
      |> Enum.map(fn {participant, position} ->
        participant_ranking_data(participant, position)
      end)
      |> then(&{:ok, &1})
    else
      {:error, :unauthorized}
    end
  end

  @doc "Publishes the ranking after the transaction that calculated it commits."
  @spec publish_ranking(integer(), [map()]) :: :ok
  def publish_ranking(game_session_id, ranking)
      when is_integer(game_session_id) and is_list(ranking) do
    Topic.broadcast(game_session_id, {:ranking_updated, ranking})
  end
end
