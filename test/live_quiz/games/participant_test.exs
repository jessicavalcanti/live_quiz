defmodule LiveQuiz.Games.ParticipantTest do
  use LiveQuiz.DataCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures

  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.Participant

  doctest LiveQuiz.Games.Participant

  setup do
    %{session: game_session_fixture()}
  end

  defp new_participant(session, attrs) do
    %Participant{
      game_session_id: session.id,
      user_id: attrs[:user_id],
      access_token_hash: Map.get(attrs, :access_token_hash, unique_access_token_hash()),
      joined_at: Map.get(attrs, :joined_at, now())
    }
  end

  defp joining(session, attrs \\ %{}, struct_attrs \\ %{}) do
    session
    |> new_participant(struct_attrs)
    |> Participant.join_changeset(Enum.into(attrs, %{nickname: "Ana"}))
  end

  describe "limits" do
    test "expose the nickname range and the digest size" do
      assert Participant.nickname_min_length() == 2
      assert Participant.nickname_max_length() == 20
      assert Participant.access_token_hash_size() == 32
    end
  end

  describe "normalize_nickname/1" do
    test "trims the ends and downcases" do
      assert Participant.normalize_nickname(" Ana ") == "ana"
      assert Participant.normalize_nickname("ANA") == "ana"
      assert Participant.normalize_nickname("ana") == "ana"
    end

    test "keeps accents and inner spaces apart" do
      assert Participant.normalize_nickname("Aná") == "aná"
      assert Participant.normalize_nickname("Ana  Paula") == "ana  paula"

      refute Participant.normalize_nickname("Ana Paula") ==
               Participant.normalize_nickname("Ana  Paula")
    end
  end

  describe "join_changeset/2" do
    test "is valid with a nickname", %{session: session} do
      changeset = joining(session)

      assert changeset.valid?
      assert get_change(changeset, :nickname) == "Ana"
    end

    test "requires a nickname", %{session: session} do
      changeset = joining(session, %{nickname: nil})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).nickname
    end

    test "rejects a nickname with a single character", %{session: session} do
      changeset = joining(session, %{nickname: "A"})

      refute changeset.valid?
      assert "should be at least 2 character(s)" in errors_on(changeset).nickname
    end

    test "accepts a nickname with exactly 2 characters", %{session: session} do
      assert joining(session, %{nickname: "An"}).valid?
    end

    test "accepts a nickname with exactly 20 characters", %{session: session} do
      assert joining(session, %{nickname: String.duplicate("a", 20)}).valid?
    end

    test "rejects a nickname with 21 characters", %{session: session} do
      changeset = joining(session, %{nickname: String.duplicate("a", 21)})

      refute changeset.valid?
      assert "should be at most 20 character(s)" in errors_on(changeset).nickname
    end

    test "measures the nickname after trimming", %{session: session} do
      changeset = joining(session, %{nickname: "  A  "})

      refute changeset.valid?
      assert "should be at least 2 character(s)" in errors_on(changeset).nickname
    end

    test "rejects a nickname with an emoji", %{session: session} do
      changeset = joining(session, %{nickname: "Ana 🎉"})

      refute changeset.valid?

      assert "use apenas letras, números, espaços, hífen e sublinhado" in errors_on(changeset).nickname
    end

    test "accepts accents, digits, inner spaces, hyphen and underscore", %{session: session} do
      for nickname <- ["Aná", "Ana Paula", "Ana-Paula", "Ana_Paula", "Ana123", "Çağla"] do
        assert joining(session, %{nickname: nickname}).valid?,
               "expected #{nickname} to be accepted"
      end
    end

    test "derives nickname_normalized and ignores whatever comes in attrs", %{session: session} do
      changeset = joining(session, %{nickname: " Ana Paula ", nickname_normalized: "hackeado"})

      assert get_change(changeset, :nickname) == "Ana Paula"
      assert get_change(changeset, :nickname_normalized) == "ana paula"
    end

    test "keeps a blanked nickname invalid on an existing participation", %{session: session} do
      changeset =
        %Participant{
          game_session_id: session.id,
          nickname: "Ana",
          nickname_normalized: "ana",
          access_token_hash: unique_access_token_hash(),
          joined_at: now()
        }
        |> Participant.join_changeset(%{nickname: nil})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).nickname
    end

    test "requires the room" do
      changeset =
        %Participant{access_token_hash: unique_access_token_hash(), joined_at: now()}
        |> Participant.join_changeset(%{nickname: "Ana"})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).game_session_id
    end

    test "requires an access token digest", %{session: session} do
      changeset = joining(session, %{}, %{access_token_hash: nil})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).access_token_hash
    end

    test "rejects an access token digest that is not 32 bytes", %{session: session} do
      changeset = joining(session, %{}, %{access_token_hash: :crypto.strong_rand_bytes(16)})

      refute changeset.valid?
      assert "deve ter exatamente 32 bytes" in errors_on(changeset).access_token_hash
    end

    test "requires joined_at", %{session: session} do
      changeset = joining(session, %{}, %{joined_at: nil})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).joined_at
    end

    test "rejects a room that does not exist" do
      assert {:error, changeset} =
               %Participant{
                 game_session_id: -1,
                 access_token_hash: unique_access_token_hash(),
                 joined_at: now()
               }
               |> Participant.join_changeset(%{nickname: "Ana"})
               |> Repo.insert()

      assert "does not exist" in errors_on(changeset).game_session
    end
  end

  describe "connection_changeset/2" do
    test "casts the connection bookkeeping", %{session: session} do
      participant = participant_fixture(session)
      connection_id = Ecto.UUID.generate()
      at = now()

      updated =
        participant
        |> Participant.connection_changeset(%{
          connection_id: connection_id,
          left_at: at,
          released_at: at
        })
        |> Repo.update!()

      assert updated.connection_id == connection_id
      assert updated.left_at == at
      assert updated.released_at == at
    end
  end

  describe "credential_changeset/2" do
    test "replaces the persisted digest", %{session: session} do
      participant = participant_fixture(session)
      digest = unique_access_token_hash()

      updated = participant |> Participant.credential_changeset(digest) |> Repo.update!()

      assert updated.access_token_hash == digest
      assert Repo.get!(Participant, participant.id).access_token_hash == digest
    end

    test "rejects a digest of the wrong size", %{session: session} do
      changeset =
        session
        |> participant_fixture()
        |> Participant.credential_changeset(:crypto.strong_rand_bytes(16))

      refute changeset.valid?
      assert %{access_token_hash: [_message | _]} = errors_on(changeset)
    end
  end

  describe "in_lobby?/1" do
    test "is true while the participation is open" do
      assert Participant.in_lobby?(%Participant{})
    end

    test "is false once the person left or was released" do
      refute Participant.in_lobby?(%Participant{left_at: now()})
      refute Participant.in_lobby?(%Participant{released_at: now()})
    end
  end

  describe "unique nickname per room" do
    test "rejects the same nickname regardless of case and outer spaces", %{session: session} do
      participant_fixture(session, %{nickname: "Ana"})

      assert {:error, changeset} =
               session |> joining(%{nickname: "  ana  "}) |> Repo.insert()

      assert "este apelido já está em uso nesta sala" in errors_on(changeset).nickname
    end

    test "accepts the same nickname in a different room", %{session: session} do
      participant_fixture(session, %{nickname: "Ana"})
      other_session = game_session_fixture()

      assert {:ok, participant} = other_session |> joining(%{nickname: "Ana"}) |> Repo.insert()
      assert participant.nickname == "Ana"
    end

    test "treats accented nicknames as different", %{session: session} do
      participant_fixture(session, %{nickname: "Ana"})

      assert {:ok, _participant} = session |> joining(%{nickname: "Aná"}) |> Repo.insert()
    end
  end

  describe "one open participation per account" do
    test "rejects a second open participation for the same account", %{session: session} do
      user = user_fixture()
      participant_fixture(session, %{user: user})
      other_session = game_session_fixture()

      assert {:error, changeset} =
               other_session
               |> joining(%{nickname: "Ana"}, %{user_id: user.id})
               |> Repo.insert()

      assert "você já está participando de outra sala" in errors_on(changeset).user_id
    end

    test "accepts a new participation once the previous one is released", %{session: session} do
      user = user_fixture()
      participant_fixture(session, %{user: user, released_at: now()})
      other_session = game_session_fixture()

      assert {:ok, participant} =
               other_session
               |> joining(%{nickname: "Ana"}, %{user_id: user.id})
               |> Repo.insert()

      assert participant.user_id == user.id
    end

    test "does not put guests against each other", %{session: session} do
      participant_fixture(session, %{nickname: "Ana"})

      assert {:ok, guest} = session |> joining(%{nickname: "Bia"}) |> Repo.insert()

      assert is_nil(guest.user_id)
      assert is_nil(guest.released_at)
      assert Repo.aggregate(participants_of(session), :count) == 2
    end
  end

  describe "unique access token digest" do
    test "rejects two participations sharing a digest", %{session: session} do
      hash = unique_access_token_hash()
      participant_fixture(session, %{access_token_hash: hash})
      other_session = game_session_fixture()

      assert {:error, changeset} =
               other_session
               |> joining(%{nickname: "Ana"}, %{access_token_hash: hash})
               |> Repo.insert()

      assert Map.has_key?(errors_on(changeset), :access_token_hash)
    end
  end

  describe "database check constraints" do
    test "rejects a nickname shorter than 2 characters when the changeset is bypassed", %{
      session: session
    } do
      assert_raise Ecto.ConstraintError, fn ->
        Repo.transaction(fn ->
          Repo.insert!(%Participant{
            game_session_id: session.id,
            nickname: "A",
            nickname_normalized: "a",
            access_token_hash: unique_access_token_hash(),
            joined_at: now()
          })
        end)
      end
    end
  end

  describe "fixtures" do
    test "unique_nickname/0 fits the accepted shape and never repeats", %{session: session} do
      nicknames = for _ <- 1..50, do: unique_nickname()

      assert length(Enum.uniq(nicknames)) == 50

      for nickname <- nicknames do
        assert String.length(nickname) in 2..20
        assert joining(session, %{nickname: nickname}).valid?
      end
    end

    test "participant_fixture/2 accepts a lifecycle state", %{session: session} do
      participant = participant_fixture(session, %{left_at: now()})

      refute Participant.in_lobby?(participant)
    end
  end

  defp participants_of(%GameSession{id: id}) do
    from p in Participant, where: p.game_session_id == ^id
  end
end
