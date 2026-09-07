defmodule LiveQuiz.Repo.Migrations.AddQuestionTotalsToGameResults do
  @moduledoc """
  Tells apart the questions a match actually applied from the ones it froze.

  `unanswered_questions` used to be the whole snapshot minus what the person
  answered, so a match finished after the first question of three filed the
  other two as absences by that person — questions nobody was ever shown.

  `played_questions` is how many of the snapshot the match reached, and
  `total_questions` how many it had. Absences are counted among the played
  ones, which is what makes `answered_questions + unanswered_questions ==
  played_questions` hold.

  Rows written before this migration are backfilled from what they already
  record: a result whose absences were counted against the whole snapshot has
  `answered + unanswered` for both totals, which is the number that row was
  built from. It is not a repair — the old rows keep the counts they were
  frozen with — only a way of not leaving the new columns null on history that
  cannot be recomputed.
  """

  use Ecto.Migration

  def up do
    alter table(:game_results) do
      add :played_questions, :integer
      add :total_questions, :integer
    end

    execute """
    UPDATE game_results
       SET played_questions = answered_questions + unanswered_questions,
           total_questions = answered_questions + unanswered_questions
     WHERE played_questions IS NULL
    """

    alter table(:game_results) do
      modify :played_questions, :integer, null: false, default: 0
      modify :total_questions, :integer, null: false, default: 0
    end

    create constraint(:game_results, :played_questions_non_negative,
             check: "played_questions >= 0"
           )

    create constraint(:game_results, :total_questions_cover_played,
             check: "total_questions >= played_questions"
           )

    create constraint(:game_results, :answers_add_up_to_played,
             check: "answered_questions + unanswered_questions = played_questions"
           )
  end

  def down do
    drop constraint(:game_results, :answers_add_up_to_played)
    drop constraint(:game_results, :total_questions_cover_played)
    drop constraint(:game_results, :played_questions_non_negative)

    alter table(:game_results) do
      remove :played_questions
      remove :total_questions
    end
  end
end
