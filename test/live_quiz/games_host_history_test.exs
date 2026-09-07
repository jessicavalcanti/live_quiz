defmodule LiveQuiz.GamesHostHistoryTest do
  use LiveQuiz.DataCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import LiveQuiz.QuizzesFixtures

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games
  alias LiveQuiz.Repo

  test "lists only finished matches hosted by the user with winner summary" do
    host = user_fixture()
    own = game_session_fixture(%{host: host, status: :finished})
    participant = participant_fixture(own, %{user: user_fixture(), nickname: "Vencedora"})
    game_result_fixture(own, participant, %{score: 900, final_position: 1})
    game_session_fixture(%{host: host, status: :cancelled})
    game_session_fixture(%{host: user_fixture(), status: :finished})

    page = Games.list_host_game_history(Scope.for_user(host), %{}, %{per_page: 20})
    entry = hd(page.entries)

    assert entry.session.id == own.id
    assert entry.participants_count == 1
    assert entry.winner_nickname == "Vencedora"
    assert entry.winner_score == 900
    assert page.total_entries == 1
  end

  test "filters host history by quiz and date and allows deleted quiz titles" do
    host = user_fixture()
    quiz = quiz_fixture(Scope.for_user(host), %{title: "Quiz preservado"})
    session = game_session_fixture(%{host: host, quiz: quiz, status: :finished})
    participant = participant_fixture(session, %{user: user_fixture()})
    result = game_result_fixture(session, participant)
    Repo.delete!(quiz)

    page =
      Games.list_host_game_history(
        Scope.for_user(host),
        %{
          from: DateTime.to_iso8601(DateTime.add(session.inserted_at, -1, :day)),
          to: DateTime.to_iso8601(DateTime.add(session.inserted_at, 1, :day))
        },
        %{per_page: 20}
      )

    assert [%{quiz_title: "Quiz preservado"}] = page.entries
    assert {:ok, loaded} = Games.get_host_game_result(Scope.for_user(host), result.id)
    assert loaded.quiz_title == "Quiz preservado"
  end

  test "host can read a complete ranking but another host cannot" do
    host = user_fixture()
    session = game_session_fixture(%{host: host, status: :finished})
    participant = participant_fixture(session, %{user: user_fixture()})
    game_result_fixture(session, participant, %{final_position: 1})

    assert {:ok, loaded} = Games.get_host_game_history(Scope.for_user(host), session.id)
    assert length(loaded.game_results) == 1

    assert {:error, :not_found} =
             Games.get_host_game_history(Scope.for_user(user_fixture()), session.id)
  end

  test "participant cannot use the host result lookup" do
    host = user_fixture()
    session = game_session_fixture(%{host: host, status: :finished})
    participant_user = user_fixture()
    participant = participant_fixture(session, %{user: participant_user})
    result = game_result_fixture(session, participant)

    assert {:error, :not_found} =
             Games.get_host_game_result(Scope.for_user(participant_user), result.id)
  end
end
