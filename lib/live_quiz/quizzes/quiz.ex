defmodule LiveQuiz.Quizzes.Quiz do
  @moduledoc """
  A quiz owned by a single user, holding an ordered list of questions.

  Deleting a quiz removes its questions and answer options through the database
  cascade declared in the migration, so the association below intentionally does
  not carry `:on_delete`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias LiveQuiz.Accounts.User
  alias LiveQuiz.Quizzes.Question

  @type t :: %__MODULE__{}

  schema "quizzes" do
    field :title, :string
    field :description, :string
    field :questions_count, :integer, virtual: true

    belongs_to :owner, User
    has_many :questions, Question, preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  @doc """
  Casts and validates the quiz attributes a user can edit.

  The owner is never cast: it comes from the caller scope and is assigned by the
  context.
  """
  def changeset(quiz, attrs) do
    quiz
    |> cast(attrs, [:title, :description])
    |> update_change(:title, &trim/1)
    |> validate_required([:title])
    |> validate_length(:title, min: 3, max: 120)
    |> validate_length(:description, max: 500)
    |> assoc_constraint(:owner)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
