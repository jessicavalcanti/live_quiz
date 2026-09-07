defmodule LiveQuiz.Games.ConnectionLeaseTest do
  @moduledoc """
  Who holds a room, and which question a command was meant for.

  Regressions for R22 and R25 of the review. Both are about a command whose
  authorization was decided somewhere other than the row it writes: the tab's
  own belief about still being the host, and the question that happened to be
  current when the lock was granted.
  """

  use LiveQuiz.DataCase, async: false

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.Presence

  describe "a command from a tab that lost the room" do
    setup :running_match

    test "cannot close the question", context do
      %{scope: scope, session: session, old_lease: old} = take_over(context)

      assert Games.close_question(scope, session, connection_id: old) ==
               {:error, :access_lost}

      refute Repo.get!(GameSession, session.id).current_question_closed_at
    end

    test "cannot advance the match", context do
      %{scope: scope, session: session, old_lease: old} = take_over(context)

      assert Games.advance_question(scope, session, 1, connection_id: old) ==
               {:error, :access_lost}

      assert Repo.get!(GameSession, session.id).current_question_position == 1
    end

    test "cannot finish the match", context do
      %{scope: scope, session: session, old_lease: old} = take_over(context)

      assert Games.finish_game_session(scope, session, connection_id: old) ==
               {:error, :access_lost}

      assert Repo.get!(GameSession, session.id).status == :in_progress
    end

    test "cannot cancel the room", context do
      %{scope: scope, session: session, old_lease: old} = take_over(context)

      assert Games.cancel_game_session(scope, session, connection_id: old) ==
               {:error, :access_lost}

      assert Repo.get!(GameSession, session.id).status == :in_progress
    end
  end

  describe "a command from the tab that holds the room" do
    setup :running_match

    test "is accepted", %{scope: scope, session: session} do
      {:ok, _session, lease} = Games.claim_host_connection(scope, session)

      assert {:ok, closed} = Games.close_question(scope, session, connection_id: lease)
      assert closed.current_question_closed_at
    end

    test "is accepted when no lease is presented at all", %{scope: scope, session: session} do
      {:ok, _session, _lease} = Games.claim_host_connection(scope, session)

      # No lease is what a REST client sends: it authenticates the account and
      # nothing else. Requiring one here would break that contract silently, so
      # the check applies only to callers that present a credential.
      assert {:ok, closed} = Games.close_question(scope, session)
      assert closed.current_question_closed_at
    end
  end

  describe "closing the question a command was meant for" do
    setup :running_match

    test "refuses a command aimed at a question the match already left", context do
      %{scope: scope, session: session} = context

      assert {:ok, advanced} = Games.advance_question(scope, session, 1)
      Games.QuestionTimer.stop(advanced.id)

      # The retry was written for question 1 and arrived after the advance. The
      # lock serializes it, and without the expected position it would close
      # question 2 instead.
      assert Games.close_question(scope, advanced, expected_position: 1) == {:error, :stale}

      current = Repo.get!(GameSession, session.id)
      assert current.current_question_position == 2
      refute current.current_question_closed_at
    end

    test "accepts a command aimed at the question that is current", context do
      %{scope: scope, session: session} = context

      assert {:ok, closed} = Games.close_question(scope, session, expected_position: 1)
      assert closed.current_question_closed_at
    end

    test "still closes the current question when no position is named", context do
      %{scope: scope, session: session} = context

      assert {:ok, closed} = Games.close_question(scope, session)
      assert closed.current_question_closed_at
    end

    test "two identical commands close once and answer the same instant", context do
      %{scope: scope, session: session} = context

      assert {:ok, first} = Games.close_question(scope, session, expected_position: 1)
      assert {:ok, again} = Games.close_question(scope, first, expected_position: 1)

      assert again.current_question_closed_at == first.current_question_closed_at
    end
  end

  describe "the host presence that decides liveness" do
    setup :running_match

    test "a tab that was taken over stops counting as the host present", %{
      scope: scope,
      session: session
    } do
      {:ok, session, first} = Games.claim_host_connection(scope, session)
      {:ok, _ref} = Presence.track_host(self(), session, first)

      assert Presence.host_connected?(session.id)
      assert Presence.host_in_control?(Repo.get!(GameSession, session.id))

      {:ok, _session, _second} = Games.claim_host_connection(scope, session)

      # The old tab is still there, and still shows up as a host presence. What
      # it is not any more is the connection holding the room, which is the only
      # thing an abandoned room's expiry may be delayed by.
      assert Presence.host_connected?(session.id)
      refute Presence.host_in_control?(Repo.get!(GameSession, session.id))
    end

    test "a room nobody claimed counts any host presence", %{session: session} do
      {:ok, _ref} = Presence.track_host(self(), session, nil)

      assert Presence.host_in_control?(Repo.get!(GameSession, session.id))
    end
  end

  defp running_match(_context) do
    host = user_fixture()
    scope = Scope.for_user(host)
    session = game_session_fixture(%{host: host, status: :in_progress})
    snapshot_fixture(session, count: 2)

    {:ok, opened} = Games.advance_question(scope, session, nil)
    Games.QuestionTimer.stop(opened.id)

    %{scope: scope, session: opened}
  end

  # The room changes hands: the first lease is what the abandoned tab still
  # presents, and the second is what the room now holds.
  defp take_over(%{scope: scope, session: session} = context) do
    {:ok, _session, old} = Games.claim_host_connection(scope, session)
    {:ok, session, _new} = Games.claim_host_connection(scope, session)

    %{context | session: session} |> Map.put(:old_lease, old)
  end
end
