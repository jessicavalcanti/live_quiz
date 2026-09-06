defmodule LiveQuiz.Games.AnswerTest do
  use LiveQuiz.DataCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import LiveQuiz.QuizzesFixtures

  alias LiveQuiz.Games.Answer
  alias LiveQuiz.Games.GameSessionQuestion

  defp valid_attrs(context, attrs) do
    Enum.into(attrs, %{
      game_session_id: context.session.id,
      game_session_question_id: context.snapshot_question.id,
      participant_id: context.participant.id,
      game_session_answer_option_id: context.option.id,
      answered_at: now_usec()
    })
  end

  defp new_answer(context, attrs \\ %{}) do
    Answer.changeset(%Answer{}, valid_attrs(context, attrs))
  end

  setup do
    scope = user_scope_fixture()
    session = game_session_fixture(%{host: scope.user, quiz: quiz_fixture(scope)})
    [snapshot_question | _rest] = snapshot_fixture(session, count: 2)
    [option | _others] = snapshot_question.answer_options

    %{
      scope: scope,
      session: session,
      snapshot_question: snapshot_question,
      option: option,
      participant: participant_fixture(session)
    }
  end

  describe "changeset/2" do
    test "is valid with the four references and an instant", context do
      changeset = new_answer(context)

      assert changeset.valid?
      assert %Answer{} = Repo.insert!(changeset)
    end

    test "requires every reference and the instant", context do
      for field <- [
            :game_session_id,
            :game_session_question_id,
            :participant_id,
            :game_session_answer_option_id,
            :answered_at
          ] do
        changeset = new_answer(context, %{field => nil})

        refute changeset.valid?
        assert "can't be blank" in errors_on(changeset)[field]
      end
    end

    test "keeps the microsecond of the instant", context do
      at = ~U[2026-09-06 12:00:00.123456Z]

      answer = Repo.insert!(new_answer(context, %{answered_at: at}))

      assert Repo.get!(Answer, answer.id).answered_at == at
    end

    test "refuses a match that does not exist", context do
      assert {:error, changeset} =
               context |> new_answer(%{game_session_id: -1}) |> Repo.insert()

      assert "does not exist" in errors_on(changeset).game_session
    end

    test "refuses a participant that does not exist", context do
      assert {:error, changeset} =
               context |> new_answer(%{participant_id: -1}) |> Repo.insert()

      assert "does not exist" in errors_on(changeset).participant
    end

    test "does not check that the question belongs to the match", context do
      # Coherence between match, question, option and participant is the
      # context's job when it records an answer (F3-04), not this schema's.
      other_session = game_session_fixture()
      [other_question | _rest] = snapshot_fixture(other_session, count: 1)

      assert new_answer(context, %{game_session_question_id: other_question.id}).valid?
    end
  end

  describe "database guarantees" do
    test "refuses a second answer of the same person to the same question", context do
      Repo.insert!(new_answer(context))

      assert {:error, changeset} = context |> new_answer() |> Repo.insert()

      assert "você já respondeu esta pergunta" in errors_on(changeset).participant_id
    end

    test "accepts the same person answering another question", context do
      [_first, second] =
        Repo.all(
          from q in GameSessionQuestion,
            where: q.game_session_id == ^context.session.id,
            order_by: [asc: q.position],
            preload: [:answer_options]
        )

      [other_option | _rest] = second.answer_options

      Repo.insert!(new_answer(context))

      assert %Answer{} =
               answer_fixture(context.participant, other_option)

      assert Repo.aggregate(
               from(a in Answer, where: a.participant_id == ^context.participant.id),
               :count
             ) == 2
    end

    test "accepts another person answering the same question", context do
      other = participant_fixture(context.session)

      Repo.insert!(new_answer(context))

      assert %Answer{} = answer_fixture(other, context.option)
    end

    test "is removed when the match is deleted", context do
      Repo.insert!(new_answer(context))

      Repo.delete!(context.session)

      assert Repo.aggregate(
               from(a in Answer, where: a.game_session_id == ^context.session.id),
               :count
             ) == 0
    end

    test "is removed when the participant is deleted", context do
      Repo.insert!(new_answer(context))

      Repo.delete!(context.participant)

      assert Repo.aggregate(
               from(a in Answer, where: a.participant_id == ^context.participant.id),
               :count
             ) == 0
    end

    test "is removed when the snapshot question is deleted", context do
      Repo.insert!(new_answer(context))

      Repo.delete!(context.snapshot_question)

      assert Repo.aggregate(
               from(a in Answer,
                 where: a.game_session_question_id == ^context.snapshot_question.id
               ),
               :count
             ) == 0
    end
  end
end
