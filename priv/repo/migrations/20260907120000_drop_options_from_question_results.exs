defmodule LiveQuiz.Repo.Migrations.DropOptionsFromQuestionResults do
  use Ecto.Migration

  @moduledoc """
  Drops the `options` array copied into every `game_results.question_results`.

  It held every alternative of every question, repeated once per participation —
  twenty-five identical copies in a full room — and no reader ever asked for
  one: the ending screens, the host's history and the API all render the
  statement, the answer that was given and whether it was right. The frozen
  alternatives are still in `game_session_answer_options`, once per match, which
  is where anything that needs them belongs.

  Irreversible on purpose: `down/0` cannot invent copies that no longer exist,
  and rebuilding them from the snapshot would be recreating exactly the
  duplication this removes.
  """

  def up do
    execute("""
    UPDATE game_results
       SET question_results = (
             SELECT jsonb_object_agg(key, value - 'options')
               FROM jsonb_each(question_results)
           )
     WHERE jsonb_typeof(question_results) = 'object'
       AND question_results <> '{}'::jsonb
    """)
  end

  def down do
    :ok
  end
end
