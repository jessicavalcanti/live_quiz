defmodule LiveQuiz.Games.GameResultTest do
  use LiveQuiz.DataCase, async: true

  import LiveQuiz.GamesFixtures
  alias LiveQuiz.Games.GameResult
  alias LiveQuiz.Repo

  setup do
    session = game_session_fixture()
    participant = participant_fixture(session)
    %{session: session, participant: participant}
  end

  defp attrs(session, participant, overrides \\ %{}) do
    Enum.into(overrides, %{
      game_session_id: session.id,
      participant_id: participant.id,
      quiz_id: session.quiz_id,
      quiz_title: session.quiz_title,
      nickname: participant.nickname,
      score: 800,
      correct_answers: 1,
      incorrect_answers: 0,
      unanswered_questions: 2,
      answered_questions: 1,
      total_response_time_ms: 1_200,
      average_response_time_ms: 1_200,
      final_position: 1,
      question_results: %{"1" => %{"correct" => true}}
    })
  end

  test "has safe metric defaults for participants", %{participant: participant} do
    assert participant.score == 0
    assert participant.correct_answers == 0
    assert participant.incorrect_answers == 0
    assert participant.total_response_time_ms == 0
    assert is_nil(participant.final_position)
  end

  test "accepts a complete JSON result snapshot", %{session: session, participant: participant} do
    changeset = GameResult.changeset(%GameResult{}, attrs(session, participant))

    assert changeset.valid?
    assert {:ok, result} = Repo.insert(changeset)
    assert result.question_results == %{"1" => %{"correct" => true}}
  end

  test "requires the game session, participant and metrics", %{
    session: session,
    participant: participant
  } do
    changeset =
      %GameResult{}
      |> GameResult.changeset(attrs(session, participant, %{game_session_id: nil, score: nil}))

    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset).game_session_id
    assert "can't be blank" in errors_on(changeset).score
  end

  test "rejects non-JSON question details", %{session: session, participant: participant} do
    changeset =
      GameResult.changeset(
        %GameResult{},
        attrs(session, participant, %{question_results: {1, 2}})
      )

    refute changeset.valid?
    assert %{question_results: [_message | _]} = errors_on(changeset)
  end

  test "enforces foreign keys and the unique participant result", %{
    session: session,
    participant: participant
  } do
    assert {:error, changeset} =
             GameResult.changeset(
               %GameResult{},
               attrs(session, participant, %{game_session_id: -1})
             )
             |> Repo.insert()

    assert "does not exist" in errors_on(changeset).game_session

    game_result_fixture(session, participant)

    assert {:error, changeset} =
             GameResult.changeset(%GameResult{}, attrs(session, participant)) |> Repo.insert()

    assert "este participante já possui resultado nesta partida" in errors_on(changeset).game_session_id
  end

  test "survives quiz deletion while retaining its snapshot", %{
    session: session,
    participant: participant
  } do
    result = game_result_fixture(session, participant)
    quiz = Repo.get!(LiveQuiz.Quizzes.Quiz, session.quiz_id)

    Repo.delete!(quiz)

    persisted = Repo.get!(GameResult, result.id)
    assert is_nil(persisted.quiz_id)
    assert persisted.quiz_title == session.quiz_title
    assert persisted.nickname == participant.nickname
  end

  test "is deleted when its game session is deleted", %{
    session: session,
    participant: participant
  } do
    result = game_result_fixture(session, participant)
    Repo.delete!(session)

    assert Repo.get(GameResult, result.id) == nil
  end
end
