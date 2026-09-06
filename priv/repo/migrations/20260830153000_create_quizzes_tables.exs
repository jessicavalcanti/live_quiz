defmodule LiveQuiz.Repo.Migrations.CreateQuizzesTables do
  use Ecto.Migration

  def change do
    create table(:quizzes) do
      add :owner_id, references(:users, on_delete: :delete_all), null: false
      add :title, :string, size: 120, null: false
      add :description, :text

      timestamps(type: :utc_datetime)
    end

    create index(:quizzes, [:owner_id])
    create index(:quizzes, [:owner_id, :updated_at])
    create constraint(:quizzes, :title_length, check: "char_length(title) between 3 and 120")

    create constraint(:quizzes, :description_length,
             check: "description is null or char_length(description) <= 500"
           )

    create table(:questions) do
      add :quiz_id, references(:quizzes, on_delete: :delete_all), null: false
      add :text, :text, null: false
      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:questions, [:quiz_id])
    create constraint(:questions, :position_must_be_positive, check: "position > 0")
    create constraint(:questions, :text_length, check: "char_length(text) between 3 and 500")

    # `create unique_index/3` cannot emit a DEFERRABLE constraint, and deferring is what allows a
    # single transaction to swap the positions of two questions without tripping over itself.
    execute(
      "ALTER TABLE questions ADD CONSTRAINT questions_quiz_id_position_key UNIQUE (quiz_id, position) DEFERRABLE INITIALLY DEFERRED",
      "ALTER TABLE questions DROP CONSTRAINT questions_quiz_id_position_key"
    )

    create table(:answer_options) do
      add :question_id, references(:questions, on_delete: :delete_all), null: false
      add :text, :string, size: 200, null: false
      add :position, :integer, null: false
      add :is_correct, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create index(:answer_options, [:question_id])
    create constraint(:answer_options, :text_length, check: "char_length(text) between 1 and 200")
    create constraint(:answer_options, :position_range, check: "position between 1 and 4")

    execute(
      "ALTER TABLE answer_options ADD CONSTRAINT answer_options_question_id_position_key UNIQUE (question_id, position) DEFERRABLE INITIALLY DEFERRED",
      "ALTER TABLE answer_options DROP CONSTRAINT answer_options_question_id_position_key"
    )

    # Guarantees "at most one correct option"; guaranteeing "at least one" belongs to the
    # question transaction and lands in F1-07.
    create unique_index(:answer_options, [:question_id],
             where: "is_correct",
             name: :answer_options_single_correct_index
           )
  end
end
