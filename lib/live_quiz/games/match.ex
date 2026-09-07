defmodule LiveQuiz.Games.Match do
  @moduledoc """
  A room while it is being played: from the moment it goes live to the moment
  it ends.

  Starting is where the content stops being a moving target. The questions, the
  options and the answer key are copied into the match and the status flips in
  one transaction (AD-36), and from there every read of what is being played
  goes to `list_snapshot_questions/1` and its neighbours — never to
  `LiveQuiz.Quizzes`. Editing or deleting the quiz afterwards cannot rewrite
  what was played.

  From there the match only goes forward. `advance_question/3` opens the next
  question, never a chosen one and never a previous one (AD-44);
  `close_question/2` reveals the answer key; `finish_game_session/2` ends the
  match when the host says so, not when the questions run out. Which question is
  being played and whether it is still taking answers are derived from columns
  of the room rather than from an enum of their own (AD-37), and the deadline is
  absolute and written by the server (AD-39) — so a screen that reconnects
  rebuilds everything from one `game_state/2` and no state ever lives only in
  memory. Each command takes the match lock, which is what makes a double click
  a `:stale` answer instead of a skipped question.

  Answering is the other half of that movement, and the only command that is not
  the host's. `answer_question/3` keeps a single row per participation and
  question and writes it with an upsert (AD-41), so changing one's mind while
  the question is open replaces the choice instead of piling another one on top,
  and two taps in the same instant cannot become two answers. That same
  transaction is where the question closes once the answers reach the number of
  people connected (AD-42).

  A question closes three ways — the host, the deadline, everybody having
  answered — and all three end in the same columns, publish the same event and
  hand the question to `LiveQuiz.Games.Scoring`. All three are idempotent, so
  they may happen at the same instant and still reveal the answer once.

  Ending the match is where it stops being a match and becomes history: the
  final positions are frozen and one `LiveQuiz.Games.GameResult` per
  participation is written, which is what `LiveQuiz.Games.History` reads from
  then on.
  """

  import Ecto.Query

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games.Access
  alias LiveQuiz.Games.Answer
  alias LiveQuiz.Games.GameResult
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.GameSessionAnswerOption
  alias LiveQuiz.Games.GameSessionQuestion
  alias LiveQuiz.Games.Locks
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Games.QuestionTimer
  alias LiveQuiz.Games.Room
  alias LiveQuiz.Games.Scoring
  alias LiveQuiz.Games.Topic
  alias LiveQuiz.Quizzes
  alias LiveQuiz.Quizzes.Question
  alias LiveQuiz.Quizzes.Quiz
  alias LiveQuiz.Repo

  @doc """
  Puts the room live, freezing the quiz into it, which is the only way out of
  the lobby.

  Only the host may start it, only from `waiting`, and only with at least one
  participant **connected** — `connected_count` is informed by whoever watches
  the presence of the room, so the rule stays in the context while the counting
  stays out of it (AD-23). Somebody merely signed up, disconnected or gone does
  not count.

  Starting copies every question of the quiz, with its options and its answer
  key, into the match, and flips the status in the **same transaction** (AD-36):
  a room that is `in_progress` without a snapshot could neither be advanced nor
  played, so either the whole content is frozen or nothing happens at all. From
  that instant the match no longer reads the quiz — see
  `list_snapshot_questions/1` — and editing or deleting the quiz afterwards
  cannot rewrite what was played.

  The quiz is checked again here, and not only when the room was opened: the
  lobby may have lasted any amount of time. A quiz that lost its questions
  answers `:quiz_not_playable`, and one that is gone answers `:quiz_unavailable`.

  Idempotent for the host: asking again for a match that is already running
  gives that match back, with the snapshot it already has and without a second
  `{:game_started, session}`. That courtesy is the host's alone — anybody else
  is `:unauthorized`, and a room that is over never reopens.
  """
  @spec start_game_session(Scope.t(), GameSession.t(), non_neg_integer()) ::
          {:ok, GameSession.t()}
          | {:error, :unauthorized}
          | {:error, :invalid_transition}
          | {:error, :no_connected_participants}
          | {:error, :quiz_not_playable}
          | {:error, :quiz_unavailable}
  def start_game_session(%Scope{} = scope, %GameSession{} = session, connected_count)
      when is_integer(connected_count) and connected_count >= 0 do
    case Room.fetch_hosted(scope, session) do
      {:ok, %GameSession{status: :in_progress} = running} -> {:ok, running}
      {:ok, %GameSession{} = current} -> start_and_announce(scope, current, connected_count)
      {:error, :unauthorized} = error -> error
    end
  end

  @doc """
  The frozen questions of a match, in order, with their options preloaded.

  This is the only content an ongoing match ever reads: it touches
  `game_session_questions` and `game_session_answer_options` and never the quiz
  tables (AD-36), so it answers just the same after the quiz has been deleted.
  """
  @spec list_snapshot_questions(GameSession.t()) :: [GameSessionQuestion.t()]
  def list_snapshot_questions(%GameSession{id: id}) do
    id
    |> snapshot_questions()
    |> order_by([q], asc: q.position)
    |> preload(:answer_options)
    |> Repo.all()
  end

  @doc """
  The frozen question at a position of a match, with its options preloaded.

  Positions run from 1 to `snapshot_question_count/1` with no gaps, whatever
  the quiz they were copied from looked like.
  """
  @spec get_snapshot_question(GameSession.t(), pos_integer()) ::
          {:ok, GameSessionQuestion.t()} | {:error, :not_found}
  def get_snapshot_question(%GameSession{id: id}, position) when is_integer(position) do
    id
    |> snapshot_questions()
    |> where([q], q.position == ^position)
    |> preload(:answer_options)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      %GameSessionQuestion{} = question -> {:ok, question}
    end
  end

  @doc """
  How many questions were frozen into the match.

  Zero for a room still in the lobby: the snapshot only exists from the start
  onwards.
  """
  @spec snapshot_question_count(GameSession.t()) :: non_neg_integer()
  def snapshot_question_count(%GameSession{id: id}) do
    id |> snapshot_questions() |> Repo.aggregate(:count, :id)
  end

  @doc """
  How many questions the room announces it is going to play.

  Before the start there is no snapshot yet, so the number can only come from
  the quiz the room was opened from — which cannot change underneath it, since
  a live room locks its quiz against edits (AD-32). From the start onwards the
  snapshot is the only source read, as the match owes nothing to the quiz any
  more (AD-36). A room whose quiz was deleted before it ever started announces
  zero, which is the truth: there is nothing left to play.
  """
  @spec question_count(GameSession.t()) :: non_neg_integer()
  def question_count(%GameSession{} = session) do
    case snapshot_question_count(session) do
      0 -> quiz_question_count(session)
      count -> count
    end
  end

  defp quiz_question_count(%GameSession{quiz_id: nil}), do: 0

  defp quiz_question_count(%GameSession{quiz_id: quiz_id}) do
    Question
    |> where([q], q.quiz_id == ^quiz_id)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Advances the match to the next question and opens it for answers.

  Advancing is the only thing that moves a match forward, and it only ever
  produces `position + 1` (AD-44): there is no destination to ask for, so there
  is no way to go back, to skip or to reopen. Opening is not a command of its
  own — a question just advanced to is already taking answers, which is what
  the refinement decided so the host has one button instead of two.

  `expected_position` is the position the caller believes is current, and `nil`
  only before the very first question. It is compared inside the transaction
  and answers `:stale` when it does not match: that is what stops two clicks —
  or one on the web and another on the API — from skipping a question between
  them.

  A question still open is closed in the same transaction before the next one
  opens, so a match never leaves a question behind with no ending.

  The deadline is absolute and computed by the server (AD-39):
  `current_question_started_at` is now and `current_question_ends_at` is that
  instant plus the duration the room was opened with.

  Only the host commands a match, and only while it is running: anybody else is
  `:unauthorized`, and a room in the lobby or already over is `:invalid_status`.
  """
  @spec advance_question(Scope.t(), GameSession.t(), pos_integer() | nil) ::
          {:ok, GameSession.t()}
          | {:error, :unauthorized | :invalid_status | :no_more_questions | :stale}
  def advance_question(%Scope{} = scope, %GameSession{} = session, expected_position)
      when is_nil(expected_position) or
             (is_integer(expected_position) and expected_position > 0) do
    with {:ok, hosted} <- Room.fetch_hosted(scope, session),
         {:ok, {advanced, effects}} <- open_next_question(hosted, expected_position) do
      publish_effects(advanced.id, effects)
      QuestionTimer.ensure_started(advanced)
      Topic.broadcast(advanced.id, {:question_advanced, advanced})
      {:ok, advanced}
    end
  end

  @doc """
  Closes the question that is open, by the host's own decision.

  Closing is what reveals the answer key; the question stays on screen, closed,
  until the host advances. It never ends the match — even the last question
  waits for `finish_game_session/2`, because finishing is a decision of the
  host and not a consequence of running out of questions.

  Idempotent: asking again for a question already closed gives the match back
  with the instant it was closed at untouched and without a second
  `{:question_closed, session}`, so a repeated click does not replay the
  reveal. A match that has not advanced to any question has nothing to close
  and answers `:no_open_question`.
  """
  @spec close_question(Scope.t(), GameSession.t()) ::
          {:ok, GameSession.t()} | {:error, :unauthorized | :invalid_status | :no_open_question}
  def close_question(%Scope{} = scope, %GameSession{} = session) do
    with {:ok, hosted} <- Room.fetch_hosted(scope, session),
         {:ok, outcome} <- close_current_question(hosted) do
      QuestionTimer.stop(hosted.id)

      case outcome do
        {:closed, closed, effects} ->
          publish_effects(closed.id, effects)
          Topic.broadcast(closed.id, {:question_closed, closed})
          {:ok, closed}

        {:already_closed, closed} ->
          {:ok, closed}
      end
    end
  end

  @doc """
  Closes the question that is open because its deadline ran out.

  It takes no scope on purpose: the caller is the timer of F3-05, that is, the
  system, exactly like `expire_game_session/1`. Nobody has to be host to let
  time pass, and no screen has to be connected for it to run out — a match whose
  host dropped keeps closing its questions on time, it simply does not advance
  on its own.

  The deadline is checked here, inside the transaction and against the database
  (AD-39): a question with time still on the clock answers `:not_due` and stays
  open, which is what makes a timer that fired early harmless. A question
  already closed — by the host, by everybody having answered or by another
  timer — gives the match back with its closing instant untouched and without a
  second `{:question_closed, session}`, so the three ways a question can end
  converge on a single reveal.

  The result is indistinguishable from `close_question/2`: same columns, same
  event. Only the origin differs.
  """
  @spec close_question_by_timeout(integer()) ::
          {:ok, GameSession.t()}
          | {:error, :not_found | :invalid_status | :no_open_question | :not_due}
  def close_question_by_timeout(session_id) when is_integer(session_id) do
    case close_due_question(session_id) do
      {:ok, {:closed, closed, effects}} ->
        publish_effects(closed.id, effects)
        Topic.broadcast(closed.id, {:question_closed, closed})
        {:ok, closed}

      {:ok, {:already_closed, closed}} ->
        {:ok, closed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Every running match sitting on a question that is still taking answers.

  This is what the boot recovery of F3-05 reads. Matches that are over never
  come back, whatever their columns say, so a cancelled room stopped mid
  question is left exactly as it was. The order is the deadline itself, so the
  most overdue question is the first one settled.
  """
  @spec list_sessions_with_open_question() :: [GameSession.t()]
  def list_sessions_with_open_question do
    GameSession
    |> where([s], s.status == :in_progress)
    |> where([s], not is_nil(s.current_question_position))
    |> where([s], is_nil(s.current_question_closed_at))
    |> order_by([s], asc: s.current_question_ends_at, asc: s.id)
    |> Repo.all()
  end

  @doc """
  The match a timer is keeping the deadline of, read without a scope.

  There is no owner to filter by: the caller is the system, like
  `close_question_by_timeout/1`. It exists so the timer can compare the position
  it was armed for with the one the match is actually on before closing
  anything — a message scheduled for question 1 and delivered after the host
  advanced must recognize itself as late and do nothing.
  """
  @spec get_session_for_timeout(integer()) :: {:ok, GameSession.t()} | {:error, :not_found}
  def get_session_for_timeout(session_id) when is_integer(session_id) do
    case Repo.get(GameSession, session_id) do
      nil -> {:error, :not_found}
      %GameSession{} = session -> {:ok, session}
    end
  end

  @doc """
  Records or replaces the answer of a participant to the question that is open.

  Changing one's mind is part of playing: while the question is open the answer
  may be sent again, and the last one is the one that counts. It is written by
  a single upsert on `(participant_id, game_session_question_id)` (AD-41), so
  two taps of the same person in the same instant end as one row instead of
  racing a `SELECT` against an `INSERT`, and the unique index never reaches the
  caller as an exception. The option and `answered_at` are both rewritten,
  because phase 4 measures the speed of the choice that stayed, not of the one
  that was abandoned.

  Whether the answer arrived in time is decided here, against
  `current_question_ends_at` as the database holds it (AD-39). A screen still
  showing the question open is not an argument: a millisecond past the deadline
  is `:time_is_up`.

  `connected_ids` are the participations the presence of the room is showing
  (AD-23), and they are used for one thing only — deciding whether this answer
  was the last one missing. It is a question about people, not about totals:
  every connected participation has to be among the ones that answered. Two
  independent counts would let an answer from somebody who has since dropped
  off stand in for somebody still connected who has not answered yet, and the
  question would close on them. When the set is complete the question is closed
  inside this very transaction, under the same advisory lock the host's commands
  take (AD-42), so two final answers cannot both conclude "only I was missing"
  and close it twice. With nobody connected the rule never fires, and the
  question waits for the deadline or for the host.

  Being connected is deliberately *not* required in order to answer: somebody
  may tap at the exact instant the presence has yet to register them, and
  refusing that would punish the player for a detail of the infrastructure.
  What is required is an active participation — whoever left the room answers
  `:left_session` — a running match, an open question, and an option of that
  very question, checked against the database instead of trusted from the id
  that arrived.

  Every accepted answer announces `{:answer_submitted, session_id, count}`
  after the commit, and `{:question_closed, session}` as well when it was the
  one that closed the question. A refused answer writes nothing and announces
  nothing.

  > Swapping the option over and over writes without a limit. That was weighed
  > in the refinement and accepted; a rate limit, if it ever becomes necessary,
  > belongs right here, before the transaction opens.
  """
  @spec answer_question(Participant.t(), integer(), Enumerable.t()) ::
          {:ok, %{answer: Answer.t(), session: GameSession.t(), closed?: boolean()}}
          | {:error,
             :invalid_status
             | :no_open_question
             | :question_closed
             | :time_is_up
             | :option_not_found
             | :left_session}
  def answer_question(%Participant{} = participant, answer_option_id, connected_ids)
      when is_integer(answer_option_id) do
    case record_answer(participant, answer_option_id, connected_ids) do
      {:ok, %{session: session, closed?: closed?, count: count, effects: effects} = recorded} ->
        Topic.broadcast(session.id, {:answer_submitted, session.id, count})

        if closed? do
          QuestionTimer.stop(session.id)
          publish_effects(session.id, effects)
          Topic.broadcast(session.id, {:question_closed, session})
        end

        {:ok, Map.take(recorded, [:answer, :session, :closed?])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  How many participations have already answered the question of the moment.

  Whoever did not answer leaves no row at all (AD-43), so this is a plain count
  and never a count of anything but real answers. Zero before the first advance.
  """
  @spec current_answers_count(GameSession.t()) :: non_neg_integer()
  def current_answers_count(%GameSession{} = session) do
    case current_question_id(session) do
      nil -> 0
      question_id -> question_id |> current_answers() |> Repo.aggregate(:count, :id)
    end
  end

  @doc """
  Ends the match by the host's own decision.

  Allowed at any point of a running match — with a question open, with one
  closed, or before the first advance — because finishing is the host's call
  and never a consequence of the questions running out.

  The match becomes `finished` with `finished_at` stamped and everybody
  released for another room in a single statement, the very ending phase 2
  gives a cancelled room (AD-22). `current_question_position` is left where it
  was: it is the record of the last question actually played.

  Idempotent for the host: a match already finished is given back without a
  second `{:game_finished, session}`. A room still in the lobby, cancelled or
  expired answers `:invalid_status` — there is nothing running to end.
  """
  @spec finish_game_session(Scope.t(), GameSession.t()) ::
          {:ok, GameSession.t()} | {:error, :unauthorized | :invalid_status}
  def finish_game_session(%Scope{} = scope, %GameSession{} = session) do
    case Room.fetch_hosted(scope, session) do
      {:ok, %GameSession{status: :finished} = finished} -> {:ok, finished}
      {:ok, %GameSession{} = current} -> finish_and_announce(current)
      {:error, :unauthorized} = error -> error
    end
  end

  @doc """
  The state of the match as the viewer is allowed to see it.

  One read rebuilds a whole screen — where the match is, what the current
  question says, when it ends and what was chosen — so a connection that comes
  back asks for this and nothing else. It always reads the database, never a
  cached struct: the match state has a single source of truth.

  `viewer` decides the shape, and the choice is made here rather than in the
  presentation layer so that the web and the API cannot drift apart. The host
  always gets the answer key, plus `answers_count` — how many people have
  answered the question of the moment, which is the only thing about the
  answers a question still open gives away. The distribution by alternative
  waits for the question to close and lives in `question_results/3`, so nobody
  is nudged into voting with the crowd. Everybody else gets `correct: nil`
  while the question is open and the real key once it closes (AD-46), plus
  `my_answer_option_id` with their own choice.

  Only the host and the people who took part may look; anybody else gets
  `:unauthorized`. Being released — which finishing the match does to
  everybody — does not take the ending screen away from whoever played.

  `seconds_left` is a courtesy for a single reading and ages the instant it is
  sent; a countdown on screen must be drawn from `ends_at`, the server's
  absolute deadline (AD-39).

      %{
        status: :in_progress,
        question_number: 2,
        question_count: 10,
        question_state: :open,
        question_text: "Qual é a capital do Brasil?",
        ends_at: ~U[2026-09-05 18:04:30.000000Z],
        seconds_left: 22,
        last_question?: false,
        options: [%{id: 41, position: 1, text: "São Paulo", correct: nil}],
        my_answer_option_id: 42
      }

  The host's shape carries `answers_count: 17` where the playing one carries
  `my_answer_option_id`.
  """
  @spec game_state(GameSession.t(), Scope.t() | Participant.t()) ::
          {:ok, map()} | {:error, :unauthorized}
  def game_state(%GameSession{} = session, viewer) do
    current = Room.reload(session)

    if Access.may_watch?(current, viewer) do
      {:ok, build_game_state(current, viewer)}
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  The tally of a question that has closed: answer key, distribution and absences.

  This is what everybody sees at the reveal, and it is the same reading for the
  host and for whoever played — the only difference is that a participant also
  learns what they had picked and whether it was right.

  The distribution is aggregated by the database and the alternatives come from
  the snapshot, so one nobody chose is listed with `count: 0` instead of
  disappearing from the screen (AD-43), and the order is always the snapshot's.
  `is_correct` is the frozen answer key (AD-36) and never a reading of the quiz,
  which is why a match whose quiz was deleted tallies just the same.

  "No answer" is a difference, never a row: `participants_count` counts the
  active participations of the match — whoever left on purpose is out, whoever
  merely dropped off is in, because they are still someone who did not answer —
  and what is left after the answers is `no_answer_count`. Both numbers are read
  in a single statement, so somebody leaving in the middle cannot produce a
  tally that does not add up.

  Only a question the match is done with is tallied. While it is open — and
  while the match has not reached it — the answer is `{:error, :question_open}`,
  so neither a screen nor an endpoint can reveal the key ahead of time (AD-46).
  A position that was never frozen is `:not_found`, and anybody who is neither
  the host nor a participant is `:unauthorized`.

      %{
        position: 2,
        question_count: 10,
        question_text: "Qual é a capital do Brasil?",
        answers_count: 22,
        no_answer_count: 3,
        participants_count: 25,
        options: [
          %{id: 41, position: 1, text: "São Paulo", is_correct: false, count: 4},
          %{id: 42, position: 2, text: "Brasília", is_correct: true, count: 15},
          %{id: 43, position: 3, text: "Rio de Janeiro", is_correct: false, count: 3},
          %{id: 44, position: 4, text: "Salvador", is_correct: false, count: 0}
        ],
        my_answer_option_id: 42,
        my_answer_correct?: true
      }

  `my_answer_option_id` and `my_answer_correct?` are `nil` for the host and for
  whoever did not answer. There is no score, no speed bonus and no position
  here: phase 4 computes those on top of exactly these numbers.
  """
  @spec question_results(GameSession.t(), pos_integer(), Scope.t() | Participant.t()) ::
          {:ok, map()} | {:error, :question_open | :not_found | :unauthorized}
  def question_results(%GameSession{} = session, position, viewer) when is_integer(position) do
    current = Room.reload(session)

    with :ok <- Access.ensure_may_watch(current, viewer),
         {:ok, question} <- get_snapshot_question(current, position),
         :ok <- GameSession.ensure_question_settled(current, position) do
      {:ok, build_question_results(current, question, viewer)}
    end
  end

  @doc """
  What a match adds up to: how far it got and how much was answered.

  `questions_played` is the position the match reached, which is the number of
  questions actually applied — a match finished on question 7 of 10 played
  seven. `answers_count` is every answer of the match, one per participation and
  question (AD-41), so a swap counts once.

  It reads the match wherever it is: asking in the middle brings what has been
  played so far, and the ending screen asks for it once the match is over. Only
  the host and the people who took part may read it.
  """
  @spec game_summary(GameSession.t(), Scope.t() | Participant.t()) ::
          {:ok, map()} | {:error, :unauthorized}
  def game_summary(%GameSession{} = session, viewer) do
    current = Room.reload(session)

    case Access.ensure_may_watch(current, viewer) do
      :ok -> {:ok, build_game_summary(current)}
      {:error, :unauthorized} = error -> error
    end
  end

  defp start_and_announce(%Scope{} = scope, %GameSession{} = session, connected_count) do
    with :ok <- ensure_startable(session, connected_count),
         {:ok, outcome} <- freeze_and_go_live(scope, session) do
      case outcome do
        # Somebody else's start committed while this one waited for the row:
        # the match is running and has its single snapshot, and announcing it
        # again would replay the beginning for everyone listening.
        {:already_started, running} -> {:ok, running}
        {:started, started} -> announce_start(started)
      end
    end
  end

  defp announce_start(%GameSession{} = session) do
    Topic.broadcast(session.id, {:game_started, session})
    {:ok, session}
  end

  defp ensure_startable(%GameSession{status: :waiting}, connected_count) do
    if connected_count > 0, do: :ok, else: {:error, :no_connected_participants}
  end

  defp ensure_startable(%GameSession{}, _connected_count), do: {:error, :invalid_transition}

  # The snapshot and the transition share one transaction (AD-36), opened by
  # locking the room's own row: whoever comes second waits there and finds the
  # match already running instead of writing a second snapshot over the unique
  # index of `(game_session_id, position)`.
  defp freeze_and_go_live(%Scope{} = scope, %GameSession{id: id}) do
    Repo.transaction(fn ->
      case Locks.session(id) do
        %GameSession{status: :waiting} = session ->
          freeze_quiz_into(scope, session)

        %GameSession{status: :in_progress} = session ->
          {:already_started, session}

        _over_or_gone ->
          Repo.rollback(:invalid_transition)
      end
    end)
  end

  defp freeze_quiz_into(%Scope{} = scope, %GameSession{} = session) do
    with {:ok, quiz} <- fetch_quiz_to_freeze(scope, session),
         :ok <- Room.ensure_playable(quiz),
         :ok <- write_snapshot(session, quiz.questions),
         {:ok, started} <- go_live(session) do
      {:started, started}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # The quiz is nullified out of the room when it is deleted, so a room with no
  # `quiz_id` is one whose quiz is already gone and needs no query to know it.
  defp fetch_quiz_to_freeze(%Scope{}, %GameSession{quiz_id: nil}), do: {:error, :quiz_unavailable}

  defp fetch_quiz_to_freeze(%Scope{} = scope, %GameSession{quiz_id: quiz_id}) do
    case Quizzes.fetch_quiz_with_questions(scope, quiz_id) do
      {:ok, %Quiz{} = quiz} -> {:ok, quiz}
      :error -> {:error, :quiz_unavailable}
    end
  end

  # Two `insert_all/3` rather than a row at a time: a full quiz is a hundred
  # options, and a hundred round trips would hold the room's row locked for no
  # reason. The options need the ids the database just handed out, so the
  # questions come back with `position` as well — the order rows are returned in
  # is not guaranteed, and the position is what correlates them.
  defp write_snapshot(%GameSession{id: session_id}, questions) do
    at = Room.now()
    questions = Enum.sort_by(questions, & &1.position)

    {_inserted, snapshot_questions} =
      Repo.insert_all(GameSessionQuestion, snapshot_question_rows(session_id, questions, at),
        returning: [:id, :position]
      )

    ids_by_position = Map.new(snapshot_questions, &{&1.position, &1.id})

    Repo.insert_all(
      GameSessionAnswerOption,
      snapshot_option_rows(questions, ids_by_position, at)
    )

    :ok
  end

  # Positions are handed out from 1 with no gaps, whatever the quiz looked like:
  # a quiz whose question 2 was deleted freezes as 1 and 2, and the execution
  # can walk the match by counting instead of hunting for the next position.
  defp snapshot_question_rows(session_id, questions, at) do
    questions
    |> Enum.with_index(1)
    |> Enum.map(fn {question, position} ->
      %{
        game_session_id: session_id,
        question_id: question.id,
        position: position,
        text: question.text,
        inserted_at: at,
        updated_at: at
      }
    end)
  end

  defp snapshot_option_rows(questions, ids_by_position, at) do
    questions
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {question, position} ->
      snapshot_question_id = Map.fetch!(ids_by_position, position)

      question.answer_options
      |> Enum.sort_by(& &1.position)
      |> Enum.with_index(1)
      |> Enum.map(fn {option, option_position} ->
        %{
          game_session_question_id: snapshot_question_id,
          original_answer_option_id: option.id,
          text: option.text,
          position: option_position,
          is_correct: option.is_correct,
          inserted_at: at,
          updated_at: at
        }
      end)
    end)
  end

  # The status in the `WHERE` is the actual guard, not the check above it: the
  # room only goes live if the database still sees it waiting, so a second
  # caller updates no row and is told the transition is invalid.
  defp go_live(%GameSession{id: id}) do
    at = Room.now()

    query = from s in GameSession, where: s.id == ^id and s.status == :waiting, select: s

    case Repo.update_all(query, set: [status: :in_progress, started_at: at, updated_at: at]) do
      {1, [session]} -> {:ok, session}
      {0, _unchanged} -> {:error, :invalid_transition}
    end
  end

  defp snapshot_questions(session_id) do
    where(GameSessionQuestion, [q], q.game_session_id == ^session_id)
  end

  # Every command that moves a match takes the advisory lock on the room first,
  # so two clicks of the same host take turns while every other room carries on
  # untouched. The lock lasts the transaction; the `WHERE` of each `UPDATE` is
  # still what decides, so a command that lost the race changes no row and is
  # told why instead of overwriting the winner.
  defp open_next_question(%GameSession{id: id}, expected_position) do
    Repo.transaction(fn ->
      Locks.match(id)

      with {:ok, running} <- GameSession.ensure_running(Repo.get(GameSession, id)),
           :ok <- ensure_current_position(running, expected_position),
           {:ok, position} <- next_position(running),
           {:ok, settled, effects} <- settle_current_question(running),
           {:ok, advanced} <- open_question(settled, position) do
        {advanced, effects}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp close_current_question(%GameSession{id: id}) do
    Repo.transaction(fn ->
      Locks.match(id)

      case GameSession.ensure_running(Repo.get(GameSession, id)) do
        {:ok, %GameSession{current_question_position: nil}} ->
          Repo.rollback(:no_open_question)

        {:ok, %GameSession{current_question_closed_at: at} = closed} when not is_nil(at) ->
          {:already_closed, closed}

        {:ok, %GameSession{} = open} ->
          close_now(open)

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  # The same lock and the same statement the host's closing takes, so the two
  # take turns and the loser writes nothing. The deadline is read inside the
  # transaction rather than trusted from the caller: a timer only knows when it
  # was armed, the row knows when the question actually ends.
  defp close_due_question(session_id) do
    Repo.transaction(fn ->
      Locks.match(session_id)

      case Repo.get(GameSession, session_id) do
        nil -> Repo.rollback(:not_found)
        %GameSession{} = session -> close_if_due(session)
      end
    end)
  end

  defp close_if_due(%GameSession{} = session) do
    case GameSession.ensure_running(session) do
      {:error, reason} ->
        Repo.rollback(reason)

      {:ok, %GameSession{current_question_position: nil}} ->
        Repo.rollback(:no_open_question)

      {:ok, %GameSession{current_question_closed_at: at} = closed} when not is_nil(at) ->
        {:already_closed, closed}

      {:ok, %GameSession{} = open} ->
        if GameSession.question_due?(open), do: close_now(open), else: Repo.rollback(:not_due)
    end
  end

  # Closing and consolidating are one step, taken inside the transaction that is
  # already holding the match lock. Scoring afterwards, in a transaction of its
  # own, left a window in which an advance or a finish could commit first: the
  # question ended up closed and never counted (R10, R12), and what did get
  # counted was measured against the next question's clock (R11). The events the
  # consolidation produces travel back out to be published after the commit —
  # announcing a ranking a rollback can still take back is the other half of the
  # same mistake.
  defp close_now(%GameSession{} = session) do
    case stamp_question_closed(session) do
      {1, [closed]} ->
        case consolidate(closed, closed.current_question_position) do
          {:ok, effects} -> {:closed, closed, effects}
          {:error, reason} -> Repo.rollback(reason)
        end

      {0, _unchanged} ->
        {:already_closed, Room.reload(session)}
    end
  end

  # Settles whatever question the match is sitting on, closing it first if it is
  # still open. Used by the transitions that must not leave a question behind:
  # advancing to the next one and finishing the match.
  defp settle_current_question(%GameSession{current_question_position: nil} = session),
    do: {:ok, session, []}

  defp settle_current_question(%GameSession{} = session) do
    settled = if GameSession.question_open?(session), do: close_open(session), else: session

    case consolidate(settled, settled.current_question_position) do
      {:ok, effects} -> {:ok, settled, effects}
      {:error, reason} -> {:error, reason}
    end
  end

  defp close_open(%GameSession{} = session) do
    case stamp_question_closed(session) do
      {1, [closed]} -> closed
      {0, _lost_the_race} -> Room.reload(session)
    end
  end

  defp consolidate(%GameSession{id: id} = session, position) do
    case Scoring.consolidate_question(session, position) do
      {:ok, %{scored?: true, ranking: ranking}} -> {:ok, [{id, {:ranking_updated, ranking}}]}
      {:ok, %{scored?: false}} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  # Everything the committed transaction wants the room to hear, announced only
  # now that it is committed.
  defp publish_effects(_session_id, effects) do
    Enum.each(effects, fn {id, message} -> Topic.broadcast(id, message) end)
  end

  # The whole chain runs in one transaction under the advisory lock of the room,
  # which is what lets the decision to close the question be taken from the very
  # count this answer produced (AD-42) and what makes it take turns with the
  # host's own commands. Nothing is written until every check has passed, so a
  # refusal leaves no trace.
  defp record_answer(
         %Participant{game_session_id: session_id} = participant,
         option_id,
         connected
       ) do
    Repo.transaction(fn ->
      Locks.match(session_id)

      # One instant for this answer, taken once the room is serialized. The
      # deadline used to be tested against one reading of the clock and
      # `answered_at` written from another, taken after several more queries: an
      # answer could pass the check and land persisted past the deadline, so the
      # instant that authorized it and the instant that scores it disagreed
      # (R14). Now the same `at` decides and is written.
      at = Room.now_usec()

      with {:ok, session} <- GameSession.ensure_running(Repo.get(GameSession, session_id)),
           :ok <- ensure_taking_answers(session, at),
           {:ok, playing} <- ensure_still_playing(participant),
           {:ok, question_id, chosen_id} <- fetch_current_option(session, option_id) do
        upsert_answer(session, question_id, playing, chosen_id, connected, at)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Taking answers is a question already advanced to, not yet closed and still
  # inside its deadline (AD-37). The three refusals are told apart because a
  # screen has a different thing to say for each one.
  defp ensure_taking_answers(%GameSession{current_question_position: nil}, _at),
    do: {:error, :no_open_question}

  defp ensure_taking_answers(%GameSession{current_question_closed_at: closed_at}, _at)
       when not is_nil(closed_at),
       do: {:error, :question_closed}

  defp ensure_taking_answers(%GameSession{current_question_ends_at: ends_at}, at) do
    # The deadline of the database is the only clock consulted (AD-39): the
    # instant the client believes in never reaches here.
    if DateTime.compare(at, ends_at) == :gt, do: {:error, :time_is_up}, else: :ok
  end

  # The participation is read back rather than trusted from the struct that
  # arrived, so a screen left open since before the person walked out cannot
  # answer on their behalf.
  defp ensure_still_playing(%Participant{id: id}) do
    Participant
    |> where([p], p.id == ^id and is_nil(p.left_at) and is_nil(p.released_at))
    |> Repo.one()
    |> case do
      nil -> {:error, :left_session}
      %Participant{} = participant -> {:ok, participant}
    end
  end

  # The option is matched against the current question of this very match, so
  # the id of an option of another question — or of another room altogether —
  # is refused instead of being written. The question comes back from the same
  # query: there is no id worth trusting here.
  defp fetch_current_option(%GameSession{} = session, option_id) do
    query =
      from o in GameSessionAnswerOption,
        join: q in GameSessionQuestion,
        on: q.id == o.game_session_question_id,
        where: o.id == ^option_id,
        where: q.game_session_id == ^session.id,
        where: q.position == ^session.current_question_position,
        select: {q.id, o.id}

    case Repo.one(query) do
      nil -> {:error, :option_not_found}
      {question_id, chosen_id} -> {:ok, question_id, chosen_id}
    end
  end

  # `inserted_at` is deliberately out of the replace list: it records when the
  # person first answered this question, and rewriting it would hand phase 4 the
  # instant of the last swap as if it were the first choice.
  defp upsert_answer(session, question_id, participant, chosen_id, connected, at) do
    answer =
      %Answer{}
      |> Answer.changeset(%{
        game_session_id: session.id,
        game_session_question_id: question_id,
        participant_id: participant.id,
        game_session_answer_option_id: chosen_id,
        answered_at: at
      })
      |> Repo.insert!(
        on_conflict: {:replace, [:game_session_answer_option_id, :answered_at, :updated_at]},
        conflict_target: [:participant_id, :game_session_question_id],
        returning: true
      )

    answered_ids = answered_participant_ids(question_id)
    count = MapSet.size(answered_ids)
    {session, closed?, effects} = close_if_everybody_answered(session, answered_ids, connected)

    %{answer: answer, session: session, closed?: closed?, count: count, effects: effects}
  end

  # "Everybody connected has answered" is a question about two sets of people,
  # and it used to be asked of two independent totals: how many answers the
  # question has against how many participations are connected. Those count
  # different populations, and an answer from somebody who has since dropped off
  # made up the difference for somebody still connected who had not answered
  # yet — A answers and disconnects, B answers, and the question closed on C
  # (R15). Now every connected participation has to be among the ones that
  # answered.
  #
  # With nobody connected there is nothing to complete, so the rule never fires
  # and the question runs to its deadline or waits for the host. Both sets are
  # read inside the transaction, which is what makes "I was the last one
  # missing" a fact instead of a guess.
  defp close_if_everybody_answered(%GameSession{} = session, answered_ids, connected) do
    connected_ids = MapSet.new(connected)

    cond do
      MapSet.size(connected_ids) == 0 ->
        {session, false, []}

      MapSet.subset?(connected_ids, answered_ids) ->
        case close_now(session) do
          {:closed, closed, effects} -> {closed, true, effects}
          {:already_closed, closed} -> {closed, false, []}
        end

      true ->
        {session, false, []}
    end
  end

  defp answered_participant_ids(question_id) do
    question_id
    |> current_answers()
    |> select([a], a.participant_id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp current_answers(question_id) do
    where(Answer, [a], a.game_session_question_id == ^question_id)
  end

  defp current_question_id(%GameSession{current_question_position: nil}), do: nil

  defp current_question_id(%GameSession{id: id, current_question_position: position}) do
    id
    |> snapshot_questions()
    |> where([q], q.position == ^position)
    |> select([q], q.id)
    |> Repo.one()
  end

  defp finish_and_announce(%GameSession{} = session) do
    case finish_match(session) do
      {:ok, {:finished, finished, effects}} ->
        QuestionTimer.stop(finished.id)
        publish_effects(finished.id, effects)
        Topic.broadcast(finished.id, {:game_finished, finished})
        {:ok, finished}

      # Another finish committed while this one waited for the lock. The match
      # is over and was announced once; saying so twice would replay the ending.
      {:ok, {:already_finished, finished}} ->
        QuestionTimer.stop(finished.id)
        {:ok, finished}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The ending phase 2 already writes for a cancelled room, with one difference:
  # only a running match may be finished, so a room still in the lobby is
  # refused instead of being closed as if it had been played. Losing the race to
  # another finish is not a failure — the match is over either way.
  # Consolidating comes before the terminal state, under the same lock. Flipping
  # the status first froze the results of a question that was still open and
  # never counted, and the scorer refuses a match that is already finished — so
  # the wrong tally was the one that stayed in the history (R12).
  defp finish_match(%GameSession{id: id}) do
    at = Room.now()

    query = from s in GameSession, where: s.id == ^id and s.status == :in_progress, select: s

    Repo.transaction(fn ->
      Locks.match(id)

      with {:ok, running} <- GameSession.ensure_running(Repo.get(GameSession, id)),
           {:ok, _settled, effects} <- settle_current_question(running),
           {1, [finished]} <-
             Repo.update_all(query,
               set: [status: :finished, finished_at: at, expires_at: nil, updated_at: at]
             ) do
        persist_final_results(finished)
        Room.release_participants(id, at)
        {:finished, finished, effects}
      else
        {0, _unchanged} -> rollback_unless_finished(id)
        {:error, :invalid_status} -> rollback_unless_finished(id)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp rollback_unless_finished(id) do
    case Repo.get(GameSession, id) do
      %GameSession{status: :finished} = finished -> {:already_finished, finished}
      _lobby_or_closed -> Repo.rollback(:invalid_status)
    end
  end

  defp persist_final_results(%GameSession{} = session) do
    ranked = session.id |> Scoring.ranking_participants() |> Enum.with_index(1)

    write_final_positions(ranked)

    questions = session.id |> snapshot_questions() |> preload(:answer_options) |> Repo.all()

    # A question the match never reached was never asked of anybody, and filing
    # it as an absence made a match finished after the first of three look like
    # two questions this person skipped (R13). Having been opened is what makes
    # a question part of the result; the ones behind it are what `total` is for.
    played = Enum.filter(questions, &(not is_nil(&1.started_at)))

    answers = Repo.all(from a in Answer, where: a.game_session_id == ^session.id)
    answer_by_participant = Enum.group_by(answers, & &1.participant_id)

    # The statement and the alternatives of a question are the same for everybody
    # who played it, so they are shaped once and each participation only merges
    # its own answer into them. The stored row stays self-contained, which is
    # what makes a result readable after the quiz is gone.
    skeleton = question_skeleton(played)
    at = Room.now()

    rows =
      Enum.map(ranked, fn {participant, position} ->
        participant_answers = Map.get(answer_by_participant, participant.id, [])
        answered_count = length(participant_answers)

        %{
          game_session_id: session.id,
          participant_id: participant.id,
          user_id: participant.user_id,
          quiz_id: session.quiz_id,
          quiz_title: session.quiz_title,
          nickname: participant.nickname,
          score: participant.score,
          correct_answers: participant.correct_answers,
          incorrect_answers: participant.incorrect_answers,
          unanswered_questions: length(played) - answered_count,
          answered_questions: answered_count,
          played_questions: length(played),
          total_questions: length(questions),
          total_response_time_ms: participant.total_response_time_ms,
          average_response_time_ms: average_response_time(participant, answered_count),
          final_position: position,
          question_results: question_result_snapshot(skeleton, played, participant_answers),
          inserted_at: at,
          updated_at: at
        }
      end)

    Repo.insert_all(GameResult, rows,
      on_conflict: :nothing,
      conflict_target: [:game_session_id, :participant_id]
    )
  end

  defp write_final_positions([]), do: :ok

  # One statement for the whole room, the same reasoning as the consolidation of
  # a question: the alternative was an `UPDATE` per participation, run while the
  # match is being closed and everybody is waiting for the ending screen.
  defp write_final_positions(ranked) do
    Repo.query!(
      """
      UPDATE participants AS p
         SET final_position = v.final_position,
             updated_at = $3
        FROM unnest($1::bigint[], $2::integer[]) AS v(id, final_position)
       WHERE p.id = v.id
      """,
      [
        Enum.map(ranked, fn {participant, _position} -> participant.id end),
        Enum.map(ranked, fn {_participant, position} -> position end),
        Room.now()
      ]
    )

    :ok
  end

  defp average_response_time(_participant, 0), do: 0

  defp average_response_time(%Participant{total_response_time_ms: total}, answered_count),
    do: div(total, answered_count)

  # What every participation of a match shares: the statement it was asked. Built
  # once per match rather than once per person.
  #
  # The alternatives used to be copied in here as well, every option of every
  # question, into every participant's row — twenty-five identical copies in a
  # full room, and nothing ever read one of them: the screens and the API render
  # the statement, the answer that was given and whether it was right. The
  # frozen alternatives still exist, once, in `game_session_answer_options`,
  # which is where anything that needs them should look.
  defp question_skeleton(questions) do
    Map.new(questions, fn question ->
      {question.id, {Integer.to_string(question.position), %{"question" => question.text}}}
    end)
  end

  defp question_result_snapshot(skeleton, questions, answers) do
    answers_by_question = Map.new(answers, &{&1.game_session_question_id, &1})

    Map.new(questions, fn question ->
      {key, shared} = Map.fetch!(skeleton, question.id)
      answer = Map.get(answers_by_question, question.id)

      chosen =
        answer &&
          Enum.find(question.answer_options, &(&1.id == answer.game_session_answer_option_id))

      {key,
       Map.merge(shared, %{
         "answer_option_id" => answer && answer.game_session_answer_option_id,
         "answer" => chosen && chosen.text,
         "correct" => chosen && chosen.is_correct,
         "answered_at" => answer && DateTime.to_iso8601(answer.answered_at),
         "response_time_ms" => (answer && answer.response_time_ms) || 0
       })}
    end)
  end

  # Comparing the position the caller believes is current is the whole
  # protection against a double command (AD-44): a flag would be reset by the
  # winner and let the loser through, while a position that already moved never
  # matches again.
  defp ensure_current_position(%GameSession{current_question_position: position}, position),
    do: :ok

  defp ensure_current_position(%GameSession{}, _expected_position), do: {:error, :stale}

  defp next_position(%GameSession{current_question_position: current} = session) do
    position = (current || 0) + 1

    if position <= snapshot_question_count(session) do
      {:ok, position}
    else
      {:error, :no_more_questions}
    end
  end

  defp stamp_question_closed(%GameSession{id: id}) do
    at = Room.now_usec()

    query =
      from s in GameSession,
        where: s.id == ^id,
        where: s.status == :in_progress,
        where: not is_nil(s.current_question_position),
        where: is_nil(s.current_question_closed_at),
        select: s

    case Repo.update_all(query,
           set: [current_question_closed_at: at, updated_at: DateTime.truncate(at, :second)]
         ) do
      {1, [closed]} ->
        stamp_snapshot_closed(closed, at)
        {1, [closed]}

      unchanged ->
        unchanged
    end
  end

  defp stamp_snapshot_closed(%GameSession{id: id, current_question_position: position}, at) do
    Repo.update_all(
      from(q in GameSessionQuestion,
        where: q.game_session_id == ^id and q.position == ^position and is_nil(q.closed_at)
      ),
      set: [closed_at: at, updated_at: DateTime.truncate(at, :second)]
    )

    :ok
  end

  # The position the match is leaving is repeated in the `WHERE`, so the second
  # of two simultaneous advances updates nothing and is answered `:stale`
  # instead of pushing the match one question further than the host asked for.
  defp open_question(%GameSession{} = session, position) do
    at = Room.now_usec()
    ends_at = DateTime.add(at, session.question_duration_seconds, :second)

    query =
      from s in GameSession,
        where: s.id == ^session.id and s.status == :in_progress,
        select: s

    query = where_current_position(query, session.current_question_position)

    case Repo.update_all(query,
           set: [
             current_question_position: position,
             current_question_started_at: at,
             current_question_ends_at: ends_at,
             current_question_closed_at: nil,
             updated_at: DateTime.truncate(at, :second)
           ]
         ) do
      {1, [advanced]} ->
        stamp_snapshot_opened(advanced, position, at, ends_at)
        {:ok, advanced}

      {0, _unchanged} ->
        {:error, :stale}
    end
  end

  # The same instants the room just got, written on the question itself. The
  # room's clock always describes the question it is currently sitting on, so it
  # is the wrong thing to measure an answer by once the match has moved on; the
  # question's own copy stays true after that (R11).
  defp stamp_snapshot_opened(%GameSession{id: id}, position, at, ends_at) do
    Repo.update_all(
      from(q in GameSessionQuestion,
        where: q.game_session_id == ^id and q.position == ^position
      ),
      set: [
        started_at: at,
        ends_at: ends_at,
        closed_at: nil,
        updated_at: DateTime.truncate(at, :second)
      ]
    )

    :ok
  end

  defp where_current_position(query, nil) do
    where(query, [s], is_nil(s.current_question_position))
  end

  defp where_current_position(query, position) do
    where(query, [s], s.current_question_position == ^position)
  end

  defp build_game_state(%GameSession{} = session, viewer) do
    state = question_state(session)
    count = snapshot_question_count(session)
    question = current_snapshot_question(session, state)
    host? = Access.host_view?(session, viewer)

    base = %{
      status: session.status,
      question_number: session.current_question_position,
      question_count: count,
      question_state: state,
      question_text: question && question.text,
      ends_at: session.current_question_ends_at,
      seconds_left: seconds_left(session, state),
      last_question?: last_question?(session, count),
      options: state_options(question, state, host?)
    }

    if host? do
      Map.put(base, :answers_count, current_answers_count(session))
    else
      Map.put(base, :my_answer_option_id, own_answer_option_id(session, question, viewer))
    end
  end

  defp build_question_results(
         %GameSession{} = session,
         %GameSessionQuestion{} = question,
         viewer
       ) do
    rows = option_distribution(session, question)
    options = Enum.map(rows, &Map.delete(&1, :participants_count))
    answers_count = Enum.reduce(options, 0, fn option, total -> total + option.count end)
    participants_count = participants_count(rows, session)
    {my_option_id, my_correct?} = own_result(session, question, viewer, options)

    %{
      position: question.position,
      question_count: snapshot_question_count(session),
      question_text: question.text,
      answers_count: answers_count,
      no_answer_count: participants_count - answers_count,
      participants_count: participants_count,
      options: options,
      my_answer_option_id: my_option_id,
      my_answer_correct?: my_correct?
    }
  end

  # One statement for the distribution and for the denominator alike. The
  # `LEFT JOIN` is what keeps an alternative nobody picked in the list with zero
  # instead of dropping it (AD-43) — the most likely mistake of this reading —
  # and the cross join carries the size of the eligible population along, so the
  # two numbers describe the same instant.
  defp option_distribution(%GameSession{id: session_id}, %GameSessionQuestion{id: question_id}) do
    from(o in GameSessionAnswerOption,
      cross_join: p in subquery(eligible_participations(session_id, question_id)),
      left_join: a in Answer,
      on: a.game_session_answer_option_id == o.id,
      where: o.game_session_question_id == ^question_id,
      group_by: [o.id, p.count],
      order_by: [asc: o.position],
      select: %{
        id: o.id,
        position: o.position,
        text: o.text,
        is_correct: o.is_correct,
        count: count(a.id),
        participants_count: p.count
      }
    )
    |> Repo.all()
  end

  # Who this question's numbers are about: everybody still in the room, plus
  # anybody who answered it and has since walked out.
  #
  # The denominator used to count only the people still in, while the bars
  # counted every answer there was. The two describe different populations, and
  # somebody who answered and then left showed up as one answer out of zero
  # participants (R15). Their answer stays counted — it was really given, and a
  # reveal that changes after the fact is worse than one that includes somebody
  # who has gone — so the population that answers for it is the one that widens.
  #
  # Whoever merely dropped off was always in: being disconnected is still not
  # having answered.
  defp eligible_participations(session_id, question_id \\ :any) do
    from p in Participant,
      as: :participant,
      where: p.game_session_id == ^session_id,
      where: is_nil(p.left_at) or exists(subquery(answers_of_participant(question_id))),
      select: %{count: count(p.id)}
  end

  defp answers_of_participant(:any) do
    from a in Answer, where: a.participant_id == parent_as(:participant).id, select: 1
  end

  defp answers_of_participant(question_id) do
    from a in Answer,
      where: a.participant_id == parent_as(:participant).id,
      where: a.game_session_question_id == ^question_id,
      select: 1
  end

  defp participants_count([%{participants_count: count} | _rest], %GameSession{}), do: count

  # A snapshot question always freezes its alternatives, so this only answers a
  # question stripped of them, and then the denominator still has to be right.
  defp participants_count([], %GameSession{id: session_id}) do
    count = Repo.aggregate(where(Participant, [p], p.game_session_id == ^session_id), :count, :id)
    count
  end

  defp own_result(%GameSession{} = session, %GameSessionQuestion{} = question, viewer, options) do
    with false <- Access.host_view?(session, viewer),
         %Participant{} = participant <- viewer_participant(session, viewer),
         option_id when is_integer(option_id) <- chosen_option_id(participant, question) do
      {option_id, correct_option?(options, option_id)}
    else
      _host_or_no_answer -> {nil, nil}
    end
  end

  defp correct_option?(options, option_id) do
    Enum.any?(options, &(&1.id == option_id and &1.is_correct))
  end

  defp build_game_summary(%GameSession{id: id} = session) do
    %{count: participants_count} = Repo.one(eligible_participations(id))

    %{
      status: session.status,
      question_count: snapshot_question_count(session),
      # Counted from the snapshot rather than from the position the room is on,
      # so the screen and the stored result answer "how much was played" from
      # the same fact (R13).
      questions_played: played_question_count(session),
      answers_count: Repo.aggregate(where(Answer, [a], a.game_session_id == ^id), :count),
      participants_count: participants_count
    }
  end

  # A question the match has moved past is settled, and the one being played is
  # settled the moment it stops taking answers. A question the match has not
  # reached yet is not settled either: the answer key of question 5 is no more
  # public while the room plays question 2 than it is while it plays question 5.
  defp played_question_count(%GameSession{id: id}) do
    id
    |> snapshot_questions()
    |> where([q], not is_nil(q.started_at))
    |> Repo.aggregate(:count, :id)
  end

  defp question_state(%GameSession{current_question_position: nil}), do: :pending

  defp question_state(%GameSession{} = session) do
    if GameSession.question_open?(session), do: :open, else: :closed
  end

  defp current_snapshot_question(%GameSession{}, :pending), do: nil

  defp current_snapshot_question(%GameSession{} = session, _state) do
    case get_snapshot_question(session, session.current_question_position) do
      {:ok, %GameSessionQuestion{} = question} -> question
      {:error, :not_found} -> nil
    end
  end

  defp state_options(nil, _state, _host?), do: []

  defp state_options(%GameSessionQuestion{} = question, state, host?) do
    Enum.map(question.answer_options, fn option ->
      %{
        id: option.id,
        position: option.position,
        text: option.text,
        correct: visible_answer_key(option, state, host?)
      }
    end)
  end

  # The answer key is the one thing a running question must not leak (AD-46):
  # while it is open, whoever is playing sees `nil` rather than a field that is
  # simply absent, so a client cannot tell "no key yet" from "wrong".
  defp visible_answer_key(%GameSessionAnswerOption{is_correct: correct}, _state, true),
    do: correct

  defp visible_answer_key(%GameSessionAnswerOption{}, :open, false), do: nil

  defp visible_answer_key(%GameSessionAnswerOption{is_correct: correct}, _state, false),
    do: correct

  defp seconds_left(%GameSession{}, :pending), do: nil
  defp seconds_left(%GameSession{current_question_ends_at: nil}, _state), do: nil
  defp seconds_left(%GameSession{}, :closed), do: 0

  defp seconds_left(%GameSession{current_question_ends_at: ends_at}, :open) do
    max(DateTime.diff(ends_at, DateTime.utc_now()), 0)
  end

  defp last_question?(%GameSession{current_question_position: nil}, _count), do: false

  defp last_question?(%GameSession{current_question_position: position}, count),
    do: position >= count

  defp own_answer_option_id(%GameSession{} = session, question, viewer) do
    with %GameSessionQuestion{} <- question,
         %Participant{} = participant <- viewer_participant(session, viewer) do
      chosen_option_id(participant, question)
    else
      _nothing_played_yet -> nil
    end
  end

  defp viewer_participant(%GameSession{}, %Participant{} = participant), do: participant

  defp viewer_participant(%GameSession{id: session_id}, %Scope{} = scope) do
    Participant
    |> where([p], p.game_session_id == ^session_id and p.user_id == ^scope.user.id)
    |> order_by([p], desc: p.id)
    |> limit(1)
    |> Repo.one()
  end

  defp chosen_option_id(%Participant{id: participant_id}, %GameSessionQuestion{id: question_id}) do
    Answer
    |> where([a], a.participant_id == ^participant_id)
    |> where([a], a.game_session_question_id == ^question_id)
    |> select([a], a.game_session_answer_option_id)
    |> Repo.one()
  end
end
