defmodule LiveQuiz.Games.GameSessionAnswerOptionTest do
  use LiveQuiz.DataCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import LiveQuiz.QuizzesFixtures

  alias LiveQuiz.Games.GameSessionAnswerOption
  alias LiveQuiz.Quizzes.AnswerOption

  defp valid_attrs(attrs) do
    Enum.into(attrs, %{text: "Brasília", position: 1, is_correct: true})
  end

  defp new_option(question, attrs \\ %{}) do
    %GameSessionAnswerOption{game_session_question_id: question.id}
    |> GameSessionAnswerOption.changeset(valid_attrs(attrs))
  end

  setup do
    scope = user_scope_fixture()
    quiz = quiz_fixture(scope)
    session = game_session_fixture(%{host: scope.user, quiz: quiz})

    %{
      scope: scope,
      quiz: quiz,
      session: session,
      snapshot_question: game_session_question_fixture(session, %{position: 1})
    }
  end

  describe "changeset/2" do
    test "is valid with text, position and answer key", %{snapshot_question: question} do
      changeset = new_option(question)

      assert changeset.valid?
      assert get_change(changeset, :text) == "Brasília"
      assert get_change(changeset, :position) == 1
      assert get_change(changeset, :is_correct) == true
    end

    test "requires the text", %{snapshot_question: question} do
      changeset = new_option(question, %{text: nil})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).text
    end

    test "requires the position", %{snapshot_question: question} do
      changeset = new_option(question, %{position: nil})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).position
    end

    test "requires the answer key", %{snapshot_question: question} do
      changeset = new_option(question, %{is_correct: nil})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).is_correct
    end

    test "defaults to an incorrect option", %{snapshot_question: question} do
      option =
        %GameSessionAnswerOption{game_session_question_id: question.id}
        |> GameSessionAnswerOption.changeset(%{text: "Salvador", position: 2})
        |> Repo.insert!()

      refute option.is_correct
    end

    test "keeps a blanked text invalid on a stored option", %{snapshot_question: question} do
      changeset =
        %GameSessionAnswerOption{
          game_session_question_id: question.id,
          text: "Brasília",
          position: 1
        }
        |> GameSessionAnswerOption.changeset(%{text: nil})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).text
    end

    test "trims the text", %{snapshot_question: question} do
      changeset = new_option(question, %{text: "  Brasília  "})

      assert get_change(changeset, :text) == "Brasília"
    end

    test "keeps the option it was copied from", %{
      scope: scope,
      quiz: quiz,
      snapshot_question: snapshot_question
    } do
      question = question_fixture(scope, quiz)
      [original | _rest] = Repo.all(from o in AnswerOption, where: o.question_id == ^question.id)

      option =
        game_session_answer_option_fixture(snapshot_question, %{original_answer_option: original})

      assert option.original_answer_option_id == original.id
    end

    test "does not enforce the four-option rule of the quiz", %{snapshot_question: question} do
      # A snapshot copies a question that was already valid; re-validating the
      # set here would only give a legitimate copy a way to be refused.
      assert %GameSessionAnswerOption{} =
               game_session_answer_option_fixture(question, %{position: 1, is_correct: true})

      assert %GameSessionAnswerOption{} =
               game_session_answer_option_fixture(question, %{position: 2, is_correct: true})
    end

    test "accepts more than four options", %{snapshot_question: question} do
      for position <- 1..5 do
        game_session_answer_option_fixture(question, %{position: position})
      end

      assert Repo.aggregate(
               from(o in GameSessionAnswerOption,
                 where: o.game_session_question_id == ^question.id
               ),
               :count
             ) == 5
    end
  end

  describe "changeset/2 text length" do
    test "rejects an empty text", %{snapshot_question: question} do
      changeset = new_option(question, %{text: ""})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).text
    end

    test "accepts a single character", %{snapshot_question: question} do
      assert new_option(question, %{text: "a"}).valid?
    end

    test "accepts exactly 200 characters", %{snapshot_question: question} do
      assert new_option(question, %{text: String.duplicate("a", 200)}).valid?
    end

    test "rejects 201 characters", %{snapshot_question: question} do
      changeset = new_option(question, %{text: String.duplicate("a", 201)})

      refute changeset.valid?
      assert "should be at most 200 character(s)" in errors_on(changeset).text
    end
  end

  describe "changeset/2 position" do
    test "rejects zero", %{snapshot_question: question} do
      changeset = new_option(question, %{position: 0})

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).position
    end

    test "rejects a negative position", %{snapshot_question: question} do
      changeset = new_option(question, %{position: -1})

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).position
    end
  end

  describe "database guarantees" do
    test "refuses a non-positive position even without the changeset", %{
      snapshot_question: question
    } do
      assert_raise Ecto.ConstraintError, ~r/position_positive/, fn ->
        %GameSessionAnswerOption{game_session_question_id: question.id}
        |> Ecto.Changeset.change(text: "Brasília", position: 0, is_correct: false)
        |> Repo.insert()
      end
    end

    test "refuses two options in the same position of a question", %{
      snapshot_question: question
    } do
      game_session_answer_option_fixture(question, %{position: 1})

      assert {:error, changeset} =
               %GameSessionAnswerOption{game_session_question_id: question.id}
               |> GameSessionAnswerOption.changeset(valid_attrs(%{position: 1}))
               |> Repo.insert()

      assert "já existe uma alternativa nesta posição" in errors_on(changeset).game_session_question_id
    end

    test "accepts the same position in another question", %{
      session: session,
      snapshot_question: question
    } do
      other = game_session_question_fixture(session, %{position: 2})

      game_session_answer_option_fixture(question, %{position: 1})

      assert %GameSessionAnswerOption{position: 1} =
               game_session_answer_option_fixture(other, %{position: 1})
    end

    test "keeps the answer key when the quiz is deleted", %{
      scope: scope,
      quiz: quiz,
      snapshot_question: snapshot_question
    } do
      question = question_fixture(scope, quiz)
      [original | _rest] = Repo.all(from o in AnswerOption, where: o.question_id == ^question.id)

      option =
        game_session_answer_option_fixture(snapshot_question, %{
          original_answer_option: original,
          is_correct: true
        })

      Repo.delete!(quiz)

      kept = Repo.get!(GameSessionAnswerOption, option.id)

      assert kept.is_correct
      assert kept.text == option.text
      assert is_nil(kept.original_answer_option_id)
    end

    test "is removed when the snapshot question is deleted", %{snapshot_question: question} do
      game_session_answer_option_fixture(question, %{position: 1})

      Repo.delete!(question)

      assert Repo.aggregate(
               from(o in GameSessionAnswerOption,
                 where: o.game_session_question_id == ^question.id
               ),
               :count
             ) == 0
    end
  end
end
