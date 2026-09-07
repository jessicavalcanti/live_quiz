defmodule LiveQuiz.GamesFixtures do
  @moduledoc """
  Test helpers for creating game sessions and participants.

  They insert through the schemas directly rather than through `LiveQuiz.Games`:
  a fixture has to place a room in any status and pin its code, which is exactly
  what the context refuses to do.

  Join codes and nicknames come from `System.unique_integer/1`, so parallel
  ExUnit runs never trip over the partial unique indexes.
  """

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.QuizzesFixtures

  import Ecto.Query

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games.Answer
  alias LiveQuiz.Games.GameResult
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.GameSessionAnswerOption
  alias LiveQuiz.Games.GameSessionQuestion
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Games.ParticipantToken
  alias LiveQuiz.Quizzes.Quiz
  alias LiveQuiz.Repo

  @join_code_alphabet String.graphemes("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
  @join_code_length 6
  @join_code_space 32 ** 6
  @question_state_fields [
    :current_question_position,
    :current_question_started_at,
    :current_question_ends_at,
    :current_question_closed_at
  ]
  @snapshot_option_texts ["Brasília", "Rio de Janeiro", "São Paulo", "Salvador"]

  @doc """
  A join code drawn from the AD-25 alphabet, unique within the test run.
  """
  @spec unique_join_code() :: String.t()
  def unique_join_code do
    [:positive]
    |> System.unique_integer()
    |> rem(@join_code_space)
    |> encode_join_code()
  end

  @doc """
  A nickname unique within the test run, short enough for the 20-character limit.
  """
  @spec unique_nickname() :: String.t()
  def unique_nickname, do: "Ana #{System.unique_integer([:positive])}"

  @doc """
  A 32-byte value shaped like the SHA-256 digest the context will store.
  """
  @spec unique_access_token_hash() :: binary()
  def unique_access_token_hash, do: :crypto.strong_rand_bytes(32)

  @doc """
  Inserts a room, creating the host and the quiz when they are not given.

  Besides the schema fields, `attrs` accepts `:host` (a `%User{}`) and `:quiz`
  (a `%Quiz{}` or `nil`, for a room whose quiz was deleted).

  The quiz it makes up when none is given comes with one complete question, so
  the room is startable the way a real one is: `start_game_session/3` freezes
  the quiz into the match and refuses one with nothing to play (F3-02).

  The `current_question_*` columns are written straight through, without a
  changeset: no changeset casts them on purpose, since moving the match from one
  question to the next belongs to the context (F3-03).
  """
  @spec game_session_fixture(map()) :: GameSession.t()
  def game_session_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    host = Map.get_lazy(attrs, :host, &user_fixture/0)
    quiz = Map.get_lazy(attrs, :quiz, fn -> playable_quiz(host) end)

    question_state = Map.take(attrs, @question_state_fields)

    {status, attrs} =
      attrs |> Map.drop([:host, :quiz | @question_state_fields]) |> Map.pop(:status)

    attrs =
      Enum.into(attrs, %{
        quiz_title: quiz_title(quiz),
        join_code: unique_join_code()
      })

    %GameSession{host_id: host.id, quiz_id: quiz && quiz.id}
    |> GameSession.create_changeset(attrs)
    |> apply_status(status)
    |> Ecto.Changeset.change(question_state)
    |> Repo.insert!()
  end

  @doc """
  Inserts a participant in the given room.

  Besides the schema fields, `attrs` accepts `:user` (a `%User{}` for someone
  with an account, or `nil` for a guest).
  """
  @spec participant_fixture(GameSession.t(), map()) :: Participant.t()
  def participant_fixture(%GameSession{} = session, attrs \\ %{}) do
    attrs = Map.new(attrs)
    user = Map.get(attrs, :user)
    lifecycle = Map.take(attrs, [:connection_id, :left_at, :released_at])

    %Participant{
      game_session_id: session.id,
      user_id: user && user.id,
      access_token_hash: Map.get(attrs, :access_token_hash) || unique_access_token_hash(),
      joined_at: Map.get(attrs, :joined_at) || now()
    }
    |> Participant.join_changeset(%{nickname: Map.get(attrs, :nickname) || unique_nickname()})
    |> Participant.connection_changeset(lifecycle)
    |> Repo.insert!()
  end

  @doc """
  Inserts a participant and answers `{participant, clear_token}`.

  Only the digest ever reaches the database, so the clear credential can only be
  known by whoever built it: this is how a test presents a token the application
  actually recognizes without going through the whole join.
  """
  @spec credentialed_participant_fixture(GameSession.t(), map()) ::
          {Participant.t(), String.t()}
  def credentialed_participant_fixture(%GameSession{} = session, attrs \\ %{}) do
    {token, hash} = ParticipantToken.build()

    participant =
      participant_fixture(session, attrs |> Map.new() |> Map.put(:access_token_hash, hash))

    {participant, token}
  end

  @doc """
  Inserts one snapshot question in the given room.

  Besides the schema fields, `attrs` accepts `:question` (the `%Question{}` it
  was copied from, or `nil` for a snapshot whose quiz is already gone). The
  position defaults to the next free one in the room.
  """
  @spec game_session_question_fixture(GameSession.t(), map()) :: GameSessionQuestion.t()
  def game_session_question_fixture(%GameSession{} = session, attrs \\ %{}) do
    attrs = Map.new(attrs)
    question = Map.get(attrs, :question)

    changes =
      attrs
      |> Map.drop([:question])
      |> Enum.into(%{
        position: next_snapshot_question_position(session),
        question_text: "Qual é a capital do Brasil?"
      })

    %GameSessionQuestion{game_session_id: session.id, question_id: question && question.id}
    |> GameSessionQuestion.changeset(changes)
    |> Repo.insert!()
  end

  @doc """
  Inserts one option of a snapshot question.

  Besides the schema fields, `attrs` accepts `:original_answer_option` (the
  `%AnswerOption{}` it was copied from, or `nil`). The position defaults to the
  next free one in the question.
  """
  @spec game_session_answer_option_fixture(GameSessionQuestion.t(), map()) ::
          GameSessionAnswerOption.t()
  def game_session_answer_option_fixture(%GameSessionQuestion{} = question, attrs \\ %{}) do
    attrs = Map.new(attrs)
    original = Map.get(attrs, :original_answer_option)

    changes =
      attrs
      |> Map.drop([:original_answer_option])
      |> Enum.into(%{
        text: "Alternativa #{System.unique_integer([:positive])}",
        position: next_snapshot_option_position(question),
        is_correct: false
      })

    %GameSessionAnswerOption{
      game_session_question_id: question.id,
      original_answer_option_id: original && original.id
    }
    |> GameSessionAnswerOption.changeset(changes)
    |> Repo.insert!()
  end

  @doc """
  Inserts a whole snapshot: `:count` questions with four options each.

  The option in position 1 is the correct one. Answers the questions in order,
  with `answer_options` preloaded, which is the shape the execution reads.
  """
  @spec snapshot_fixture(GameSession.t(), keyword()) :: [GameSessionQuestion.t()]
  def snapshot_fixture(%GameSession{} = session, opts \\ []) do
    count = Keyword.get(opts, :count, 3)

    for position <- 1..count//1 do
      question =
        game_session_question_fixture(session, %{
          position: position,
          question_text: "Pergunta #{position} da partida"
        })

      for {text, option_position} <- Enum.with_index(@snapshot_option_texts, 1) do
        game_session_answer_option_fixture(question, %{
          text: text,
          position: option_position,
          is_correct: option_position == 1
        })
      end

      Repo.preload(question, :answer_options)
    end
  end

  @doc """
  Inserts the answer of a participant to the question the option belongs to.

  The match and the question are taken from the participation and the option, so
  a fixture never builds an answer that points at two different rooms.
  """
  @spec answer_fixture(Participant.t(), GameSessionAnswerOption.t(), map()) :: Answer.t()
  def answer_fixture(
        %Participant{} = participant,
        %GameSessionAnswerOption{} = option,
        attrs \\ %{}
      ) do
    attrs = Map.new(attrs)

    %Answer{}
    |> Answer.changeset(%{
      game_session_id: participant.game_session_id,
      game_session_question_id: option.game_session_question_id,
      participant_id: participant.id,
      game_session_answer_option_id: option.id,
      answered_at: Map.get(attrs, :answered_at) || now_usec()
    })
    |> Repo.insert!()
  end

  @doc "Inserts a complete immutable result snapshot for a participant."
  @spec game_result_fixture(GameSession.t(), Participant.t(), map()) :: GameResult.t()
  def game_result_fixture(%GameSession{} = session, %Participant{} = participant, attrs \\ %{}) do
    attrs = Map.new(attrs)

    %GameResult{
      game_session_id: session.id,
      participant_id: participant.id,
      user_id: participant.user_id,
      quiz_id: session.quiz_id
    }
    |> GameResult.changeset(
      Enum.into(attrs, %{
        quiz_title: session.quiz_title,
        nickname: participant.nickname,
        score: participant.score,
        correct_answers: participant.correct_answers,
        incorrect_answers: participant.incorrect_answers,
        unanswered_questions: 0,
        answered_questions: participant.correct_answers + participant.incorrect_answers,
        total_response_time_ms: participant.total_response_time_ms,
        average_response_time_ms: participant.total_response_time_ms,
        final_position: participant.final_position || 1,
        question_results: %{}
      })
    )
    |> Repo.insert!()
  end

  @doc "The current instant with the second precision the schemas persist."
  @spec now() :: DateTime.t()
  def now, do: DateTime.truncate(DateTime.utc_now(), :second)

  @doc """
  The current instant with the microsecond precision the execution persists.

  The columns of phase 3 keep the fraction that the phase 4 speed bonus needs,
  so their fixtures must not truncate to the second like `now/0` does.
  """
  @spec now_usec() :: DateTime.t()
  def now_usec, do: DateTime.utc_now()

  defp next_snapshot_question_position(%GameSession{} = session) do
    position =
      Repo.one(
        from q in GameSessionQuestion,
          where: q.game_session_id == ^session.id,
          select: max(q.position)
      )

    (position || 0) + 1
  end

  defp next_snapshot_option_position(%GameSessionQuestion{} = question) do
    position =
      Repo.one(
        from o in GameSessionAnswerOption,
          where: o.game_session_question_id == ^question.id,
          select: max(o.position)
      )

    (position || 0) + 1
  end

  defp playable_quiz(host) do
    scope = Scope.for_user(host)
    quiz = quiz_fixture(scope)
    question_fixture(scope, quiz)

    quiz
  end

  defp quiz_title(%Quiz{title: title}), do: title
  defp quiz_title(nil), do: "Quiz removido"

  defp apply_status(changeset, nil), do: changeset
  defp apply_status(%Ecto.Changeset{valid?: false} = changeset, _status), do: changeset

  defp apply_status(changeset, status) do
    changeset
    |> Ecto.Changeset.apply_changes()
    |> GameSession.status_changeset(status)
  end

  defp encode_join_code(number) do
    Enum.map_join(1..@join_code_length, fn position ->
      index = number |> div(32 ** (position - 1)) |> rem(32)
      Enum.at(@join_code_alphabet, index)
    end)
  end
end
