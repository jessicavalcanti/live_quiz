defmodule LiveQuiz.Games.QuizLock do
  @moduledoc """
  Consulta de bloqueio de quiz por sala ativa.

  Existe como módulo próprio para que `LiveQuiz.Quizzes` possa aplicar a regra
  sem depender do contexto `LiveQuiz.Games`, que por sua vez depende de
  `Quizzes`. Só lê `game_sessions` e a linha do quiz — não escreve nada.

  A regra é derivada do estado, não de uma coluna: um quiz está bloqueado
  enquanto existir ao menos uma sala em `waiting` ou `in_progress` apontando
  para ele, e volta a ser editável assim que a última delas é encerrada.
  """

  import Ecto.Query

  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Quizzes.Quiz
  alias LiveQuiz.Repo

  @doc """
  Indica se o quiz possui alguma sala em `waiting` ou `in_progress`.

  Um id inexistente responde `false`: quem não tem sala não está bloqueado.
  """
  @spec locked?(integer() | String.t()) :: boolean()
  def locked?(quiz_id) do
    GameSession
    |> where([s], s.quiz_id == ^quiz_id)
    |> active()
    |> Repo.exists?()
  end

  @doc """
  Conjunto dos ids bloqueados, para uma lista de quizzes.

  Resolve em uma consulta só, qualquer que seja o tamanho da lista. Ids sem
  sala ativa simplesmente não aparecem no conjunto.
  """
  @spec locked_ids([integer()]) :: MapSet.t(integer())
  def locked_ids([]), do: MapSet.new()

  def locked_ids(quiz_ids) when is_list(quiz_ids) do
    GameSession
    |> where([s], s.quiz_id in ^quiz_ids)
    |> active()
    |> distinct(true)
    |> select([s], s.quiz_id)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Query composável que marca o campo virtual `locked?` na seleção.

  É um `EXISTS` correlacionado dentro do próprio `SELECT`, não uma consulta por
  linha: a listagem paginada continua resolvendo no mesmo número de consultas
  de antes. A query recebida precisa nomear a origem dos quizzes como `:quiz`,
  que é a âncora do `parent_as/1`.
  """
  @spec with_lock_flag(Ecto.Query.t()) :: Ecto.Query.t()
  def with_lock_flag(query) do
    from q in query, select_merge: %{locked?: exists(active_sessions_of_parent_quiz())}
  end

  @doc """
  Trava a linha do quiz com `FOR UPDATE` e devolve o seu id.

  Tomada pelos dois lados da corrida — por `LiveQuiz.Quizzes` antes de gravar e
  por `LiveQuiz.Games` antes de abrir a sala —, é ela que fecha a janela entre
  verificar o bloqueio e gravar: sem a trava, a sala poderia nascer entre as
  duas coisas e a edição passaria assim mesmo.

  Levanta `Ecto.NoResultsError` quando o quiz não existe. Só faz sentido dentro
  de uma transação, já que a trava é liberada quando ela termina.
  """
  @spec lock_quiz!(integer() | String.t()) :: integer()
  def lock_quiz!(quiz_id) do
    Repo.one!(from q in Quiz, where: q.id == ^quiz_id, select: q.id, lock: "FOR UPDATE")
  end

  defp active_sessions_of_parent_quiz do
    GameSession
    |> where([s], s.quiz_id == parent_as(:quiz).id)
    |> active()
    |> select([s], 1)
  end

  defp active(query) do
    where(query, [s], s.status in ^GameSession.active_statuses())
  end
end
