defmodule LiveQuiz.Games.ResultsTest do
  use LiveQuiz.DataCase, async: false

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameResult
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Quizzes.Quiz
  alias LiveQuiz.Repo

  test "finishes a game and persists one detailed result per participant" do
    host = user_fixture()
    participant_user = user_fixture()
    session = game_session_fixture(%{host: host, status: :in_progress})
    [question] = snapshot_fixture(session, count: 1)
    participant = participant_fixture(session, %{user: participant_user})
    option = hd(question.answer_options)
    answer_fixture(participant, option)

    assert {:ok, finished} = Games.finish_game_session(Scope.for_user(host), session)
    assert finished.status == :finished
    assert Repo.aggregate(GameResult, :count) == 1
    assert Repo.get!(Participant, participant.id).final_position == 1

    assert {:ok, result} = Games.get_game_result(Scope.for_user(host), session.id, participant.id)
    assert result.quiz_title == session.quiz_title
    assert result.question_results["1"]["question"] == question.question_text
    assert result.question_results["1"]["answer"] == option.text
  end

  test "finishing twice and concurrently is idempotent" do
    host = user_fixture()
    session = game_session_fixture(%{host: host, status: :in_progress})
    participant_fixture(session)
    scope = Scope.for_user(host)
    :ok = Games.subscribe(session.id)

    results =
      1..2
      |> Task.async_stream(fn _ -> Games.finish_game_session(scope, session) end, ordered: true)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %GameSession{status: :finished}}, &1))
    assert {:ok, _} = Games.finish_game_session(scope, session)
    assert Repo.aggregate(GameResult, :count) == 1
    assert_receive {:game_finished, %GameSession{status: :finished}}
    refute_receive {:game_finished, _session}
  end

  test "only the host or the participant can read a result" do
    host = user_fixture()
    other = user_fixture()
    session = game_session_fixture(%{host: host, status: :in_progress})
    participant = participant_fixture(session)
    {:ok, _} = Games.finish_game_session(Scope.for_user(host), session)

    assert {:ok, _} = Games.get_game_result(Scope.for_user(host), session.id, participant.id)
    assert {:ok, _} = Games.get_game_result(participant, session.id, participant.id)

    assert {:error, :not_found} =
             Games.get_game_result(Scope.for_user(other), session.id, participant.id)

    assert {:error, :not_found} = Games.get_game_result(nil, session.id, participant.id)
  end

  test "lists only finished results with pagination and filters" do
    host = user_fixture()
    scope = Scope.for_user(host)
    session = game_session_fixture(%{host: host, status: :in_progress})
    participant_fixture(session, %{user: host})
    {:ok, finished} = Games.finish_game_session(scope, session)

    assert %{entries: [%GameResult{}], total_entries: 1, total_pages: 1} =
             Games.list_game_results(scope, %{quiz_id: finished.quiz_id}, %{per_page: 10})
  end

  test "keeps a result after the quiz is deleted" do
    host = user_fixture()
    session = game_session_fixture(%{host: host, status: :in_progress})
    participant = participant_fixture(session)
    {:ok, _} = Games.finish_game_session(Scope.for_user(host), session)
    quiz = Repo.get!(Quiz, session.quiz_id)
    Repo.delete!(quiz)

    assert {:ok, result} = Games.get_game_result(Scope.for_user(host), session.id, participant.id)
    assert result.quiz_title == session.quiz_title
    assert is_nil(result.quiz_id)
  end
end
