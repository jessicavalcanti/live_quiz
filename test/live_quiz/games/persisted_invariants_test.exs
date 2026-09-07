defmodule LiveQuiz.Games.PersistedInvariantsTest do
  @moduledoc """
  The rules that hold even when no changeset runs.

  Regression for R35 of the review. Consolidating a question and freezing a
  result are written with `insert_all` and raw SQL, for the reason recorded in
  `LiveQuiz.Games.Scoring`: twenty-five participations should not cost fifty
  statements inside the transaction holding the match lock. A changeset never
  runs on those paths, so every rule that lived only in one was a rule those
  writes could break.

  So these tests write straight past the changesets — which is exactly what the
  batch paths do — and check the database refuses.
  """

  use LiveQuiz.DataCase, async: true

  import LiveQuiz.GamesFixtures

  alias LiveQuiz.Games.Participant

  describe "métricas de uma participação" do
    setup :participant

    test "não podem ficar negativas", %{participant: participant} do
      for column <- ~w(score correct_answers incorrect_answers total_response_time_ms) do
        assert_constraint_error("metrics_non_negative", fn ->
          set(participant, column, -1)
        end)
      end
    end

    test "a posição final começa em um", %{participant: participant} do
      assert_constraint_error("final_position_positive", fn ->
        set(participant, "final_position", 0)
      end)
    end

    test "a posição final pode ser nula antes de a partida terminar", %{
      participant: participant
    } do
      assert {:ok, _result} = set(participant, "final_position", nil)
    end

    test "os valores legítimos continuam passando", %{participant: participant} do
      assert {:ok, _score} = set(participant, "score", 0)
      assert {:ok, _position} = set(participant, "final_position", 1)
    end
  end

  describe "o detalhe congelado de um resultado" do
    setup :participant

    test "é um objeto, nunca uma lista", %{session: session, participant: participant} do
      result = game_result_fixture(session, participant)

      assert_constraint_error("question_results_is_an_object", fn ->
        Repo.query(
          "UPDATE game_results SET question_results = '[]'::jsonb WHERE id = $1",
          [result.id]
        )
      end)
    end

    test "o padrão da coluna é o mesmo objeto que os escritores produzem" do
      %{rows: [[default]]} =
        Repo.query!("""
        SELECT column_default FROM information_schema.columns
         WHERE table_name = 'game_results' AND column_name = 'question_results'
        """)

      assert default =~ "'{}'"
    end
  end

  describe "uma resposta pertence a uma partida só" do
    test "a pergunta tem de ser da partida nomeada" do
      %{session: session, participant: participant, option: option} = answerable()
      other = answerable()

      assert_constraint_error("answers_question_belongs_to_session", fn ->
        insert_answer(session.id, other.question.id, participant.id, option.id)
      end)
    end

    test "a participação tem de ser da partida nomeada" do
      %{session: session, question: question, option: option} = answerable()
      other = answerable()

      assert_constraint_error("answers_participant_belongs_to_session", fn ->
        insert_answer(session.id, question.id, other.participant.id, option.id)
      end)
    end

    test "a alternativa tem de ser da pergunta nomeada" do
      %{session: session, question: question, participant: participant} = answerable()
      other = answerable()

      assert_constraint_error("answers_option_belongs_to_question", fn ->
        insert_answer(session.id, question.id, participant.id, other.option.id)
      end)
    end

    test "a resposta coerente continua passando" do
      %{session: session, question: question, participant: participant, option: option} =
        answerable()

      assert {:ok, _inserted} =
               insert_answer(session.id, question.id, participant.id, option.id)
    end
  end

  defp participant(_context) do
    session = game_session_fixture()

    %{session: session, participant: participant_fixture(session)}
  end

  defp answerable do
    session = game_session_fixture(%{status: :in_progress})
    [question] = snapshot_fixture(session, count: 1)

    %{
      session: session,
      question: question,
      participant: participant_fixture(session),
      option: hd(question.answer_options)
    }
  end

  # Escreve direto na coluna, sem changeset: é o que as escritas em lote fazem.
  defp set(%Participant{id: id}, column, value) do
    Repo.query("UPDATE participants SET #{column} = $1 WHERE id = $2", [value, id])
  end

  defp insert_answer(session_id, question_id, participant_id, option_id) do
    Repo.query(
      """
      INSERT INTO answers
        (game_session_id, game_session_question_id, participant_id,
         game_session_answer_option_id, answered_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, NOW(), NOW(), NOW())
      """,
      [session_id, question_id, participant_id, option_id]
    )
  end

  defp assert_constraint_error(name, fun) do
    assert {:error, %Postgrex.Error{postgres: %{constraint: ^name}}} = fun.(),
           "esperava a constraint #{name}"
  end
end
