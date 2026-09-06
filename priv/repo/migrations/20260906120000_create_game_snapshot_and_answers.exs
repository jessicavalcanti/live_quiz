defmodule LiveQuiz.Repo.Migrations.CreateGameSnapshotAndAnswers do
  use Ecto.Migration

  @moduledoc """
  The frozen content of a match and the answers given to it.

  A quiz is a living document: reading the questions straight from it during a
  match would let a later edit rewrite what was played. Copying statements,
  options and the correct one when the match starts is what makes the record
  truthful, so `question_id` and `original_answer_option_id` are nullable and
  `ON DELETE SET NULL` — deleting the quiz must not take the history with it.

  The state of the current question lives in columns of `game_sessions` rather
  than in a new enum (AD-37): open is a position filled with no
  `current_question_closed_at`, closed is that timestamp set. A parallel enum
  would be a second source of truth about the same fact.

  The timestamps of the execution are `utc_datetime_usec`, unlike the
  second-precision columns of phase 2: the speed bonus of phase 4 measures the
  distance between the question opening and the answer, and whole seconds would
  tie half the room.

  `UNIQUE(participant_id, game_session_question_id)` is the last layer of "one
  answer per person per question" (AD-41) and the target the upsert of F3-04
  needs; the context is still the one that validates it first.
  """

  def change do
    alter table(:game_sessions) do
      add :question_duration_seconds, :integer, null: false, default: 30
      add :current_question_position, :integer
      add :current_question_started_at, :utc_datetime_usec
      add :current_question_ends_at, :utc_datetime_usec
      add :current_question_closed_at, :utc_datetime_usec
    end

    create constraint(:game_sessions, :question_duration_allowed,
             check: "question_duration_seconds IN (10, 20, 30, 60)"
           )

    create table(:game_session_questions) do
      add :game_session_id, references(:game_sessions, on_delete: :delete_all), null: false
      add :question_id, references(:questions, on_delete: :nilify_all)
      add :position, :integer, null: false
      add :question_text, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:game_session_questions, [:game_session_id, :position])
    create index(:game_session_questions, [:question_id])
    create constraint(:game_session_questions, :position_positive, check: "position > 0")

    create table(:game_session_answer_options) do
      add :game_session_question_id,
          references(:game_session_questions, on_delete: :delete_all),
          null: false

      add :original_answer_option_id, references(:answer_options, on_delete: :nilify_all)
      add :text, :string, size: 200, null: false
      add :position, :integer, null: false
      add :is_correct, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    # Named explicitly: the generated name would be 67 characters and Postgres
    # would silently truncate it to 63, leaving the changeset pointing at an
    # index that does not exist.
    create unique_index(:game_session_answer_options, [:game_session_question_id, :position],
             name: :game_session_answer_options_position_index
           )

    create constraint(:game_session_answer_options, :position_positive, check: "position > 0")

    create table(:answers) do
      add :game_session_id, references(:game_sessions, on_delete: :delete_all), null: false

      add :game_session_question_id,
          references(:game_session_questions, on_delete: :delete_all),
          null: false

      add :participant_id, references(:participants, on_delete: :delete_all), null: false

      add :game_session_answer_option_id,
          references(:game_session_answer_options, on_delete: :delete_all),
          null: false

      add :answered_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:answers, [:participant_id, :game_session_question_id])
    create index(:answers, [:game_session_question_id])
    create index(:answers, [:game_session_id])
  end
end
