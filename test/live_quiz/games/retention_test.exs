defmodule LiveQuiz.Games.RetentionTest do
  use LiveQuiz.DataCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games
  alias LiveQuiz.Games.{Answer, GameResult, GameSession, Participant}
  alias LiveQuiz.Repo

  setup do
    host = user_fixture()
    user = user_fixture()
    session = game_session_fixture(%{host: host, status: :finished})
    participant = participant_fixture(session, %{user: user})
    guest = participant_fixture(session)
    [question] = snapshot_fixture(session, count: 1, played: 1)
    answer = answer_fixture(participant, hd(question.answer_options))
    result = game_result_fixture(session, participant)
    guest_result = game_result_fixture(session, guest)

    %{
      host: host,
      user: user,
      session: session,
      participant: participant,
      result: result,
      guest_result: guest_result,
      answer: answer
    }
  end

  test "host deletion preserves personal history and rejects unrelated viewers", context do
    Repo.delete!(context.host)
    assert Repo.get!(GameSession, context.session.id).host_id == nil

    assert Repo.get!(GameResult, context.result.id).question_results ==
             context.result.question_results

    assert Repo.get!(Answer, context.answer.id)
    scope = Scope.for_user(context.user)
    assert {:ok, _} = Games.get_my_game_result(scope, context.result.id)
    assert %{total_entries: 1} = Games.list_game_results(scope, %{}, %{})

    assert {:error, :not_found} =
             Games.get_my_game_result(Scope.for_user(user_fixture()), context.result.id)

    assert Repo.get!(GameResult, context.guest_result.id)
  end

  test "account deletion removes its copied identity but preserves other players", context do
    Repo.delete!(context.user)
    refute Repo.get(Participant, context.participant.id)
    refute Repo.get(Answer, context.answer.id)
    refute Repo.get(GameResult, context.result.id)
    assert Repo.get!(GameResult, context.guest_result.id) == context.guest_result
  end

  test "participation deletion removes individual data only", context do
    Repo.delete!(context.participant)
    refute Repo.get(Answer, context.answer.id)
    refute Repo.get(GameResult, context.result.id)
    assert Repo.get!(GameResult, context.guest_result.id) == context.guest_result
  end

  test "room deletion removes all its results and answers", context do
    Repo.delete!(context.session)
    refute Repo.get(Participant, context.participant.id)
    refute Repo.get(Answer, context.answer.id)
    refute Repo.get(GameResult, context.result.id)
    refute Repo.get(GameResult, context.guest_result.id)
  end

  test "active host deletion is rejected without partially deleting history", context do
    active = game_session_fixture(%{host: context.host})

    changeset =
      context.host
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.check_constraint(:id, name: :active_session_requires_host)

    assert {:error, _} = Repo.delete(changeset, mode: :savepoint)
    assert Repo.get!(GameSession, active.id).host_id == context.host.id
    assert Repo.get!(GameResult, context.result.id)
  end
end
