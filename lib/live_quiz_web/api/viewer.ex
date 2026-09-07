defmodule LiveQuizWeb.Api.Viewer do
  @moduledoc """
  Offers every identity a request carries to a read, and keeps the first answer.

  A request under the participant pipeline may arrive with an account, with a
  participation, or with both — the plug reads a JWT just as well as a
  participation credential, and somebody logged in who also joined a room has
  two ways of being entitled to the same reading. The contexts decide
  entitlement, one viewer at a time, so the web layer's only job is to not stop
  at the first `:unauthorized`.

  Doing that by hand is where the endpoints drifted apart: `/state`,
  `/results` and `/participants` each tried both identities, while `/ranking`
  took `current_scope || current_participant` and never got to the second one.
  Somebody logged into an account who had joined the room as a guest was
  refused the ranking and served everything else on the same screen.

  A refusal that is not about identity — a question still open, a match that
  does not exist — ends the search at once, so the caller reads why instead of
  a blanket `403`.
  """

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games.Participant
  alias Plug.Conn

  @typedoc "Whoever the request managed to be: an account, a participation, or both."
  @type identity :: Scope.t() | Participant.t()

  @doc """
  Runs `read` for each identity the request carries, keeping the first answer
  that is not an identity refusal.

  Answers `{:error, :unauthorized}` when every identity was refused. A request
  carrying none at all never reaches here: the pipeline that assigns them stops
  it at `401` first.
  """
  @spec read(Conn.t(), (identity() -> {:ok, term()} | {:error, atom()})) ::
          {:ok, term()} | {:error, atom()}
  def read(%Conn{} = conn, read) when is_function(read, 1) do
    conn
    |> identities()
    |> Enum.reduce_while({:error, :unauthorized}, fn identity, refusal ->
      case read.(identity) do
        {:error, :unauthorized} -> {:cont, refusal}
        answer -> {:halt, answer}
      end
    end)
  end

  @doc """
  Every identity the request carries, account first.

  The order is not a precedence — `read/2` tries all of them — but it keeps the
  host's reading of their own room resolving in a single query in the common
  case.
  """
  @spec identities(Conn.t()) :: [identity()]
  def identities(%Conn{} = conn) do
    Enum.reject([conn.assigns[:current_scope], conn.assigns[:current_participant]], &is_nil/1)
  end
end
