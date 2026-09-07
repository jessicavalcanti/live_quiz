defmodule LiveQuiz.Repo.Migrations.RenameQuestionTextOnSnapshot do
  use Ecto.Migration

  @moduledoc """
  Renames `game_session_questions.question_text` to `text`.

  The snapshot of an alternative already calls its statement `text`, exactly as
  the quiz it was copied from does; only the snapshot of a question carried the
  prefix, so the same value had two names depending on which of the four tables
  you were reading.

  The `question_text` key of the API is untouched — `/state` and the reveal
  endpoint keep answering with it, and the context maps the column onto it.
  """

  def change do
    rename table(:game_session_questions), :question_text, to: :text
  end
end
