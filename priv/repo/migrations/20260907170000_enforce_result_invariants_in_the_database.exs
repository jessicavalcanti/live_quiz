defmodule LiveQuiz.Repo.Migrations.EnforceResultInvariantsInTheDatabase do
  @moduledoc """
  Puts the rules the changesets already state where the batch writes can see them.

  Consolidating a question and freezing a result are written with `insert_all`
  and raw SQL, for the reason recorded in `LiveQuiz.Games.Scoring`: twenty-five
  participations should not cost fifty statements inside the transaction that
  holds the match lock. A changeset never runs on those paths, so every rule
  that lived only in one was a rule those writes could break (R35).

  Three kinds of rule move down here:

  **Metrics cannot be negative, and a final position starts at one.** Nothing
  writes a negative score today; what the constraint buys is that nothing can.

  **`question_results` is an object.** The column defaulted to `'[]'::jsonb`
  while the schema and every writer produce a map keyed by position. The default
  was never used — the writers always supply the value — but a default that
  contradicts the type is a trap for the next writer, and the check is what says
  which one is right.

  **An answer belongs to one match.** The four foreign keys were independent, so
  the database would accept an answer whose question, participant and option
  each existed and belonged to three different rooms. Composite keys tie them
  together; the unique indexes above them are what those keys need to point at.

  Nothing here changes a row. If any of it failed, the failure would be an
  inventory to look at rather than a constraint to relax.
  """

  use Ecto.Migration

  def up do
    create constraint(:participants, :metrics_non_negative,
             check: """
             score >= 0
             AND correct_answers >= 0
             AND incorrect_answers >= 0
             AND total_response_time_ms >= 0
             """
           )

    create constraint(:participants, :final_position_positive,
             check: "final_position IS NULL OR final_position > 0"
           )

    create constraint(:game_results, :metrics_non_negative,
             check: """
             score >= 0
             AND correct_answers >= 0
             AND incorrect_answers >= 0
             AND answered_questions >= 0
             AND unanswered_questions >= 0
             AND total_response_time_ms >= 0
             AND average_response_time_ms >= 0
             """
           )

    create constraint(:game_results, :final_position_positive, check: "final_position > 0")

    execute "ALTER TABLE game_results ALTER COLUMN question_results SET DEFAULT '{}'::jsonb",
            "ALTER TABLE game_results ALTER COLUMN question_results SET DEFAULT '[]'::jsonb"

    create constraint(:game_results, :question_results_is_an_object,
             check: "jsonb_typeof(question_results) = 'object'"
           )

    # What the composite keys below point at. The id alone is already unique, so
    # these add no new restriction on the referenced tables — they exist so the
    # pair can be referenced at all.
    create unique_index(:game_session_questions, [:id, :game_session_id],
             name: :game_session_questions_id_session_index
           )

    create unique_index(:game_session_answer_options, [:id, :game_session_question_id],
             name: :game_session_answer_options_id_question_index
           )

    create unique_index(:participants, [:id, :game_session_id],
             name: :participants_id_session_index
           )

    execute """
            ALTER TABLE answers
              ADD CONSTRAINT answers_question_belongs_to_session
              FOREIGN KEY (game_session_question_id, game_session_id)
              REFERENCES game_session_questions (id, game_session_id)
              ON DELETE CASCADE
            """,
            "ALTER TABLE answers DROP CONSTRAINT answers_question_belongs_to_session"

    execute """
            ALTER TABLE answers
              ADD CONSTRAINT answers_participant_belongs_to_session
              FOREIGN KEY (participant_id, game_session_id)
              REFERENCES participants (id, game_session_id)
              ON DELETE CASCADE
            """,
            "ALTER TABLE answers DROP CONSTRAINT answers_participant_belongs_to_session"

    execute """
            ALTER TABLE answers
              ADD CONSTRAINT answers_option_belongs_to_question
              FOREIGN KEY (game_session_answer_option_id, game_session_question_id)
              REFERENCES game_session_answer_options (id, game_session_question_id)
              ON DELETE CASCADE
            """,
            "ALTER TABLE answers DROP CONSTRAINT answers_option_belongs_to_question"
  end

  def down do
    execute "ALTER TABLE answers DROP CONSTRAINT answers_option_belongs_to_question"
    execute "ALTER TABLE answers DROP CONSTRAINT answers_participant_belongs_to_session"
    execute "ALTER TABLE answers DROP CONSTRAINT answers_question_belongs_to_session"

    drop unique_index(:participants, [:id, :game_session_id],
           name: :participants_id_session_index
         )

    drop unique_index(:game_session_answer_options, [:id, :game_session_question_id],
           name: :game_session_answer_options_id_question_index
         )

    drop unique_index(:game_session_questions, [:id, :game_session_id],
           name: :game_session_questions_id_session_index
         )

    drop constraint(:game_results, :question_results_is_an_object)
    execute "ALTER TABLE game_results ALTER COLUMN question_results SET DEFAULT '[]'::jsonb"
    drop constraint(:game_results, :final_position_positive)
    drop constraint(:game_results, :metrics_non_negative)
    drop constraint(:participants, :final_position_positive)
    drop constraint(:participants, :metrics_non_negative)
  end
end
