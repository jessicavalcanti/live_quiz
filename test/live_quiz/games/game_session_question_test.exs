defmodule LiveQuiz.Games.GameSessionQuestionTest do
  use LiveQuiz.DataCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import LiveQuiz.QuizzesFixtures

  alias LiveQuiz.Games.GameSessionQuestion
  alias LiveQuiz.Quizzes.Question

  defp valid_attrs(attrs) do
    Enum.into(attrs, %{position: 1, text: "Qual é a capital do Brasil?"})
  end

  defp new_snapshot_question(session, attrs \\ %{}) do
    %GameSessionQuestion{game_session_id: session.id}
    |> GameSessionQuestion.changeset(valid_attrs(attrs))
  end

  setup do
    scope = user_scope_fixture()
    quiz = quiz_fixture(scope)

    %{
      scope: scope,
      quiz: quiz,
      session: game_session_fixture(%{host: scope.user, quiz: quiz})
    }
  end

  describe "changeset/2" do
    test "is valid with a position and a statement", %{session: session} do
      changeset = new_snapshot_question(session)

      assert changeset.valid?
      assert get_change(changeset, :position) == 1
      assert get_change(changeset, :text) == "Qual é a capital do Brasil?"
    end

    test "requires the position", %{session: session} do
      changeset = new_snapshot_question(session, %{position: nil})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).position
    end

    test "requires the statement", %{session: session} do
      changeset = new_snapshot_question(session, %{text: nil})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).text
    end

    test "trims the statement", %{session: session} do
      changeset = new_snapshot_question(session, %{text: "  Capital?  "})

      assert get_change(changeset, :text) == "Capital?"
    end

    test "keeps a blanked statement invalid on a stored snapshot question", %{session: session} do
      changeset =
        %GameSessionQuestion{game_session_id: session.id, text: "Capital?", position: 1}
        |> GameSessionQuestion.changeset(%{text: nil})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).text
    end

    test "keeps the question it was copied from", %{scope: scope, quiz: quiz, session: session} do
      question = question_fixture(scope, quiz)

      snapshot =
        %GameSessionQuestion{game_session_id: session.id}
        |> GameSessionQuestion.changeset(valid_attrs(%{question_id: question.id}))
        |> Repo.insert!()

      assert snapshot.question_id == question.id
    end
  end

  describe "changeset/2 statement length" do
    test "rejects an empty statement", %{session: session} do
      changeset = new_snapshot_question(session, %{text: ""})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).text
    end

    test "accepts a single character", %{session: session} do
      assert new_snapshot_question(session, %{text: "?"}).valid?
    end

    test "accepts exactly 500 characters", %{session: session} do
      assert new_snapshot_question(session, %{text: String.duplicate("a", 500)}).valid?
    end

    test "rejects 501 characters", %{session: session} do
      changeset = new_snapshot_question(session, %{text: String.duplicate("a", 501)})

      refute changeset.valid?
      assert "should be at most 500 character(s)" in errors_on(changeset).text
    end
  end

  describe "changeset/2 position" do
    test "rejects zero", %{session: session} do
      changeset = new_snapshot_question(session, %{position: 0})

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).position
    end

    test "rejects a negative position", %{session: session} do
      changeset = new_snapshot_question(session, %{position: -1})

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).position
    end
  end

  describe "database guarantees" do
    test "refuses a non-positive position even without the changeset", %{session: session} do
      assert_raise Ecto.ConstraintError, ~r/position_positive/, fn ->
        %GameSessionQuestion{game_session_id: session.id}
        |> Ecto.Changeset.change(position: 0, text: "Capital?")
        |> Repo.insert()
      end
    end

    test "refuses two questions in the same position of a match", %{session: session} do
      game_session_question_fixture(session, %{position: 1})

      assert {:error, changeset} =
               %GameSessionQuestion{game_session_id: session.id}
               |> GameSessionQuestion.changeset(valid_attrs(%{position: 1}))
               |> Repo.insert()

      assert "já existe uma pergunta nesta posição" in errors_on(changeset).game_session_id
    end

    test "accepts the same position in another match", %{session: session} do
      other = game_session_fixture()

      game_session_question_fixture(session, %{position: 1})

      assert %GameSessionQuestion{position: 1} =
               game_session_question_fixture(other, %{position: 1})
    end

    test "keeps the snapshot when the quiz is deleted", %{scope: scope, quiz: quiz} do
      finished = game_session_fixture(%{host: scope.user, quiz: quiz, status: :finished})
      questions = for position <- 1..3, do: question_fixture(scope, quiz, %{position: position})

      snapshot =
        for {question, position} <- Enum.with_index(questions, 1) do
          game_session_question_fixture(finished, %{question: question, position: position})
        end

      Repo.delete!(quiz)

      kept = Repo.all(from q in GameSessionQuestion, where: q.game_session_id == ^finished.id)

      assert length(kept) == 3
      assert Enum.all?(kept, &is_nil(&1.question_id))
      assert Enum.sort(Enum.map(kept, & &1.id)) == Enum.sort(Enum.map(snapshot, & &1.id))
      assert Repo.aggregate(from(q in Question, where: q.quiz_id == ^quiz.id), :count) == 0
    end

    test "is removed when the match is deleted", %{session: session} do
      game_session_question_fixture(session, %{position: 1})

      Repo.delete!(session)

      assert Repo.aggregate(
               from(q in GameSessionQuestion, where: q.game_session_id == ^session.id),
               :count
             ) == 0
    end
  end
end
