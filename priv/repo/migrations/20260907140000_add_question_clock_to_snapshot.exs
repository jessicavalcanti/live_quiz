defmodule LiveQuiz.Repo.Migrations.AddQuestionClockToSnapshot do
  @moduledoc """
  Gives every snapshot question its own clock.

  Until now the only clock a match had was the one on `game_sessions`, which
  always describes the question the room is *currently* sitting on. Scoring read
  it, so an answer consolidated after the match had already moved on was
  measured against the next question's start — a two-second answer worth 800
  points came out as a zero-millisecond answer worth 1000.

  The three columns are nullable and stay that way: rows written before this
  migration have no recoverable clock, and there is no honest value to invent
  for them. Filling them with zero or with `NOW()` would turn missing
  information into wrong information, so unscored old rows are left visible as
  what they are.
  """

  use Ecto.Migration

  def change do
    alter table(:game_session_questions) do
      add :started_at, :utc_datetime_usec
      add :ends_at, :utc_datetime_usec
      add :closed_at, :utc_datetime_usec
    end
  end
end
