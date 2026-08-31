defmodule LiveQuiz.Games.GameSessionTest do
  use LiveQuiz.DataCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import LiveQuiz.QuizzesFixtures

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Accounts.User
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Quizzes.Quiz

  defp valid_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{quiz_title: "Capitais do Brasil", join_code: "K7P4Q2"})
  end

  defp new_session(host), do: %GameSession{host_id: host.id}

  describe "status helpers" do
    test "statuses/0 lists the five states of the database type" do
      assert GameSession.statuses() == [
               :waiting,
               :in_progress,
               :finished,
               :cancelled,
               :expired
             ]
    end

    test "active_statuses/0 lists only the live ones" do
      assert GameSession.active_statuses() == [:waiting, :in_progress]
    end

    test "closed_statuses/0 lists the ones a room is over in" do
      assert GameSession.closed_statuses() == [:finished, :cancelled, :expired]
    end

    test "active?/1 follows active_statuses/0" do
      for status <- GameSession.statuses() do
        assert GameSession.active?(%GameSession{status: status}) ==
                 status in GameSession.active_statuses()
      end
    end

    test "join_code_length/0 and join_code_alphabet/0 expose the AD-25 code shape" do
      assert GameSession.join_code_length() == 6
      assert GameSession.join_code_alphabet() == "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
      refute GameSession.join_code_alphabet() =~ "0"
      refute GameSession.join_code_alphabet() =~ "1"
      refute GameSession.join_code_alphabet() =~ "O"
      refute GameSession.join_code_alphabet() =~ "I"
    end
  end

  describe "create_changeset/2" do
    setup do
      %{host: user_fixture()}
    end

    test "is valid with a quiz title and a join code", %{host: host} do
      changeset = GameSession.create_changeset(new_session(host), valid_attrs())

      assert changeset.valid?
      assert get_change(changeset, :quiz_title) == "Capitais do Brasil"
      assert get_change(changeset, :join_code) == "K7P4Q2"
    end

    test "starts waiting", %{host: host} do
      session = apply_changes(GameSession.create_changeset(new_session(host), valid_attrs()))

      assert session.status == :waiting
      assert GameSession.active?(session)
    end

    test "upcases the join code", %{host: host} do
      changeset =
        GameSession.create_changeset(new_session(host), valid_attrs(%{join_code: "k7p4q2"}))

      assert changeset.valid?
      assert get_change(changeset, :join_code) == "K7P4Q2"
    end

    test "trims the quiz title", %{host: host} do
      changeset =
        GameSession.create_changeset(
          new_session(host),
          valid_attrs(%{quiz_title: "  Geografia  "})
        )

      assert get_change(changeset, :quiz_title) == "Geografia"
    end

    test "requires a quiz title", %{host: host} do
      changeset = GameSession.create_changeset(new_session(host), valid_attrs(%{quiz_title: nil}))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).quiz_title
    end

    test "rejects a quiz title shorter than 3 characters", %{host: host} do
      changeset =
        GameSession.create_changeset(new_session(host), valid_attrs(%{quiz_title: "AB"}))

      refute changeset.valid?
      assert "should be at least 3 character(s)" in errors_on(changeset).quiz_title
    end

    test "rejects a quiz title longer than 120 characters", %{host: host} do
      long_title = String.duplicate("a", 121)

      changeset =
        GameSession.create_changeset(new_session(host), valid_attrs(%{quiz_title: long_title}))

      refute changeset.valid?
      assert "should be at most 120 character(s)" in errors_on(changeset).quiz_title
    end

    test "requires a join code", %{host: host} do
      changeset = GameSession.create_changeset(new_session(host), valid_attrs(%{join_code: nil}))

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).join_code
    end

    test "rejects a join code with a character outside the alphabet", %{host: host} do
      for code <- ["K7P4Q0", "K7P4QI", "K7P4Q1", "K7P4QO", "K7P4Q-"] do
        changeset =
          GameSession.create_changeset(new_session(host), valid_attrs(%{join_code: code}))

        refute changeset.valid?, "expected #{code} to be rejected"
        assert Map.has_key?(errors_on(changeset), :join_code)
      end
    end

    test "rejects a join code that is not exactly 6 characters", %{host: host} do
      for code <- ["K7P4Q", "K7P4Q23"] do
        changeset =
          GameSession.create_changeset(new_session(host), valid_attrs(%{join_code: code}))

        refute changeset.valid?, "expected #{code} to be rejected"
        assert "should be 6 character(s)" in errors_on(changeset).join_code
      end
    end

    test "keeps a blanked title and code invalid on an existing room", %{host: host} do
      changeset =
        %GameSession{host_id: host.id, quiz_title: "Capitais do Brasil", join_code: "K7P4Q2"}
        |> GameSession.create_changeset(%{quiz_title: nil, join_code: nil})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).quiz_title
      assert "can't be blank" in errors_on(changeset).join_code
    end

    test "requires a host" do
      changeset = GameSession.create_changeset(%GameSession{}, valid_attrs())

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).host_id
    end
  end

  describe "status_changeset/3" do
    test "stamps started_at when the room goes live" do
      session = game_session_fixture()
      at = DateTime.truncate(~U[2026-08-31 12:00:00Z], :second)

      changeset = GameSession.status_changeset(session, :in_progress, at: at)

      assert get_change(changeset, :status) == :in_progress
      assert get_change(changeset, :started_at) == at
    end

    test "keeps the original started_at when the room goes live twice" do
      session = game_session_fixture(%{status: :in_progress})

      changeset = GameSession.status_changeset(session, :in_progress)

      refute Map.has_key?(changeset.changes, :started_at)
    end

    test "stamps finished_at and clears the deadline when the room closes" do
      session = game_session_fixture()

      session =
        session
        |> GameSession.host_presence_changeset(%{expires_at: DateTime.add(now(), 300, :second)})
        |> Repo.update!()

      at = DateTime.truncate(~U[2026-08-31 13:00:00Z], :second)

      updated =
        session
        |> GameSession.status_changeset(:cancelled, at: at)
        |> Repo.update!()

      assert updated.status == :cancelled
      assert updated.finished_at == at
      assert is_nil(updated.expires_at)
      refute GameSession.active?(updated)
    end

    test "closes the room for every terminal status" do
      for status <- GameSession.closed_statuses() do
        session = game_session_fixture()
        updated = session |> GameSession.status_changeset(status) |> Repo.update!()

        assert updated.status == status
        assert updated.finished_at
      end
    end

    test "rejects a status outside the database type" do
      changeset = GameSession.status_changeset(game_session_fixture(), :paused)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end

    test "refuses to send a started room back to waiting" do
      session = game_session_fixture()
      started = session |> GameSession.status_changeset(:in_progress) |> Repo.update!()

      assert {:error, changeset} =
               started |> GameSession.status_changeset(:waiting) |> Repo.update()

      assert "não pode ter início registrado enquanto a sala aguarda participantes" in errors_on(
               changeset
             ).started_at
    end
  end

  describe "host_presence_changeset/2" do
    test "casts the host connection bookkeeping" do
      session = game_session_fixture()
      connection_id = Ecto.UUID.generate()
      disconnected_at = now()
      expires_at = DateTime.add(disconnected_at, 300, :second)

      updated =
        session
        |> GameSession.host_presence_changeset(%{
          host_connection_id: connection_id,
          host_disconnected_at: disconnected_at,
          expires_at: expires_at
        })
        |> Repo.update!()

      assert updated.host_connection_id == connection_id
      assert updated.host_disconnected_at == disconnected_at
      assert updated.expires_at == expires_at
    end
  end

  describe "unique join code among live rooms" do
    test "rejects a second live room with the same code" do
      game_session_fixture(%{join_code: "K7P4Q2"})

      assert {:error, changeset} =
               %GameSession{host_id: user_fixture().id}
               |> GameSession.create_changeset(valid_attrs(%{join_code: "K7P4Q2"}))
               |> Repo.insert()

      assert "já existe uma sala ativa com este código" in errors_on(changeset).join_code
    end

    test "accepts a code reused after the room was cancelled" do
      game_session_fixture(%{join_code: "K7P4Q2", status: :cancelled})

      assert {:ok, session} =
               %GameSession{host_id: user_fixture().id}
               |> GameSession.create_changeset(valid_attrs(%{join_code: "K7P4Q2"}))
               |> Repo.insert()

      assert session.join_code == "K7P4Q2"
    end
  end

  describe "one live room per host" do
    test "rejects a second live room for the same host" do
      host = user_fixture()
      game_session_fixture(%{host: host})

      assert {:error, changeset} =
               %GameSession{host_id: host.id}
               |> GameSession.create_changeset(valid_attrs(%{join_code: unique_join_code()}))
               |> Repo.insert()

      assert "você já possui uma sala ativa" in errors_on(changeset).host_id
    end

    test "accepts a new room once the previous one is cancelled" do
      host = user_fixture()
      game_session_fixture(%{host: host, status: :cancelled})

      assert {:ok, session} =
               %GameSession{host_id: host.id}
               |> GameSession.create_changeset(valid_attrs(%{join_code: unique_join_code()}))
               |> Repo.insert()

      assert session.host_id == host.id
    end
  end

  describe "database check constraints" do
    test "rejects a join code outside the alphabet even when the changeset is bypassed" do
      host = user_fixture()

      assert_raise Ecto.ConstraintError, fn ->
        Repo.transaction(fn ->
          Repo.insert!(%GameSession{
            host_id: host.id,
            quiz_title: "Capitais do Brasil",
            join_code: "K7P4Q0"
          })
        end)
      end
    end

    test "rejects a started_at on a room that is still waiting" do
      host = user_fixture()

      assert_raise Ecto.ConstraintError, fn ->
        Repo.transaction(fn ->
          Repo.insert!(%GameSession{
            host_id: host.id,
            quiz_title: "Capitais do Brasil",
            join_code: unique_join_code(),
            started_at: now()
          })
        end)
      end
    end
  end

  describe "cascades" do
    test "deleting a room deletes its participants" do
      session = game_session_fixture()
      for _ <- 1..3, do: participant_fixture(session)

      assert Repo.aggregate(participants_of(session), :count) == 3

      Repo.delete!(session)

      assert Repo.aggregate(participants_of(session), :count) == 0
    end

    test "deleting the quiz keeps the room with a null quiz_id and the copied title" do
      host = user_fixture()
      quiz = quiz_fixture(Scope.for_user(host), %{title: "Geografia"})
      session = game_session_fixture(%{host: host, quiz: quiz, status: :cancelled})

      Repo.delete!(quiz)

      reloaded = Repo.get!(GameSession, session.id)

      assert is_nil(reloaded.quiz_id)
      assert reloaded.quiz_title == "Geografia"
    end

    test "deleting the host deletes the rooms and nullifies the participations" do
      host = user_fixture()
      hosted = game_session_fixture(%{host: host})

      other_session = game_session_fixture()
      participation = participant_fixture(other_session, %{user: host})

      Repo.delete!(host)

      refute Repo.get(GameSession, hosted.id)
      assert Repo.get!(Participant, participation.id).user_id == nil
    end

    test "the quiz knows the rooms created from it" do
      host = user_fixture()
      quiz = quiz_fixture(Scope.for_user(host))
      session = game_session_fixture(%{host: host, quiz: quiz})

      quiz = Repo.preload(Repo.get!(Quiz, quiz.id), :game_sessions)

      assert Enum.map(quiz.game_sessions, & &1.id) == [session.id]
    end

    test "the user knows the rooms it hosts and the ones it joined" do
      host = user_fixture()
      hosted = game_session_fixture(%{host: host})
      participation = participant_fixture(game_session_fixture(), %{user: host})

      user = Repo.preload(Repo.get!(User, host.id), [:hosted_game_sessions, :participations])

      assert Enum.map(user.hosted_game_sessions, & &1.id) == [hosted.id]
      assert Enum.map(user.participations, & &1.id) == [participation.id]
    end
  end

  describe "fixtures" do
    test "unique_join_code/0 only draws from the alphabet and never repeats" do
      codes = for _ <- 1..50, do: unique_join_code()

      assert length(Enum.uniq(codes)) == 50

      for code <- codes do
        assert String.length(code) == 6
        assert code =~ ~r/^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{6}$/
      end
    end

    test "game_session_fixture/1 creates its own host and quiz" do
      session = game_session_fixture()

      assert session.host_id
      assert session.quiz_id
      assert session.quiz_title
    end

    test "game_session_fixture/1 accepts a room without a quiz" do
      session = game_session_fixture(%{quiz: nil})

      assert is_nil(session.quiz_id)
      assert session.quiz_title == "Quiz removido"
    end
  end

  defp participants_of(%GameSession{id: id}) do
    from p in Participant, where: p.game_session_id == ^id
  end
end
