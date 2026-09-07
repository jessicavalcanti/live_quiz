defmodule LiveQuiz.Games.RankingTest do
  use LiveQuiz.DataCase, async: false

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.Participant

  test "orders by score, correct answers, response time and id with sequential positions" do
    host = user_fixture()
    session = game_session_fixture(%{host: host, status: :in_progress})
    first = participant_fixture(session, %{nickname: "Primeiro"})
    second = participant_fixture(session, %{nickname: "Segundo"})
    third = participant_fixture(session, %{nickname: "Terceiro"})
    fourth = participant_fixture(session, %{nickname: "Quarto"})

    Repo.update_all(from(p in Participant, where: p.id == ^first.id),
      set: [score: 500, correct_answers: 1, total_response_time_ms: 300]
    )

    Repo.update_all(from(p in Participant, where: p.id == ^second.id),
      set: [score: 500, correct_answers: 2, total_response_time_ms: 900]
    )

    Repo.update_all(from(p in Participant, where: p.id == ^third.id),
      set: [score: 500, correct_answers: 2, total_response_time_ms: 100]
    )

    Repo.update_all(from(p in Participant, where: p.id == ^fourth.id),
      set: [score: 500, correct_answers: 2, total_response_time_ms: 100]
    )

    assert {:ok, ranking} = Games.current_ranking(session, Scope.for_user(host))
    assert Enum.map(ranking, & &1.nickname) == ["Terceiro", "Quarto", "Segundo", "Primeiro"]
    assert Enum.map(ranking, & &1.position) == [1, 2, 3, 4]
    assert Enum.map(ranking, & &1.participant_id) == [third.id, fourth.id, second.id, first.id]
  end

  test "keeps disconnected participants and does not expose the answer key" do
    host = user_fixture()
    session = game_session_fixture(%{host: host, status: :in_progress})
    participant = participant_fixture(session, %{connection_id: nil})

    assert {:ok, [entry]} = Games.current_ranking(session, participant)
    assert entry.nickname == participant.nickname
    refute Map.has_key?(entry, :correct)
    refute Map.has_key?(entry, :is_correct)
  end

  test "allows only the host and participants of the same room" do
    host = user_fixture()
    other_host = user_fixture()
    session = game_session_fixture(%{host: host, status: :in_progress})
    other_session = game_session_fixture(%{host: other_host, status: :in_progress})
    participant = participant_fixture(session)
    outsider = participant_fixture(other_session)

    assert {:ok, _ranking} = Games.current_ranking(session, Scope.for_user(host))
    assert {:ok, _ranking} = Games.current_ranking(session, participant)
    assert Games.current_ranking(session, Scope.for_user(other_host)) == {:error, :unauthorized}
    assert Games.current_ranking(session, outsider) == {:error, :unauthorized}
    assert Games.current_ranking(session, nil) == {:error, :unauthorized}
  end

  test "publishes one ranking after a question is scored, including concurrent closes" do
    %{session: session, question: question} = closed_context()
    participant = participant_fixture(session)
    correct = Enum.find(question.answer_options, & &1.is_correct)
    answer_fixture(participant, correct, %{answered_at: session.current_question_started_at})
    :ok = Games.subscribe(session.id)

    results =
      1..2
      |> Task.async_stream(fn _ -> Games.score_closed_question(session, 1) end, ordered: true)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert_receive {:ranking_updated, ranking}
    assert length(ranking) == 1
    refute_receive {:ranking_updated, _ranking}
  end

  defp closed_context do
    session = game_session_fixture(%{status: :in_progress, question_duration_seconds: 10})
    [question] = snapshot_fixture(session, count: 1)
    started_at = ~U[2026-09-06 12:00:00.000000Z]
    closed_at = DateTime.add(started_at, 10, :second)

    Repo.update_all(from(s in GameSession, where: s.id == ^session.id),
      set: [
        current_question_position: 1,
        current_question_started_at: started_at,
        current_question_ends_at: closed_at,
        current_question_closed_at: closed_at
      ]
    )

    %{
      session: %{
        session
        | current_question_position: 1,
          current_question_started_at: started_at,
          current_question_ends_at: closed_at,
          current_question_closed_at: closed_at
      },
      question: question
    }
  end
end
