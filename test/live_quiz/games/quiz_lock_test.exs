defmodule LiveQuiz.Games.QuizLockTest do
  use LiveQuiz.DataCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import LiveQuiz.QuizzesFixtures

  alias LiveQuiz.Games.QuizLock
  alias LiveQuiz.Quizzes.Quiz

  setup do
    scope = user_scope_fixture()

    %{scope: scope, quiz: quiz_fixture(scope)}
  end

  describe "locked?/1" do
    test "é verdadeiro com uma sala aguardando participantes", %{quiz: quiz} do
      game_session_fixture(%{quiz: quiz, status: :waiting})

      assert QuizLock.locked?(quiz.id)
    end

    test "é verdadeiro com uma sala em andamento", %{quiz: quiz} do
      game_session_fixture(%{quiz: quiz, status: :in_progress})

      assert QuizLock.locked?(quiz.id)
    end

    test "é falso com uma sala cancelada", %{quiz: quiz} do
      game_session_fixture(%{quiz: quiz, status: :cancelled})

      refute QuizLock.locked?(quiz.id)
    end

    test "é falso com uma sala expirada", %{quiz: quiz} do
      game_session_fixture(%{quiz: quiz, status: :expired})

      refute QuizLock.locked?(quiz.id)
    end

    test "é falso com uma sala encerrada", %{quiz: quiz} do
      game_session_fixture(%{quiz: quiz, status: :finished})

      refute QuizLock.locked?(quiz.id)
    end

    test "é falso para um quiz sem nenhuma sala", %{quiz: quiz} do
      refute QuizLock.locked?(quiz.id)
    end

    test "é falso para um quiz inexistente" do
      refute QuizLock.locked?(-1)
    end

    test "é verdadeiro quando só uma das salas está ativa", %{quiz: quiz} do
      game_session_fixture(%{quiz: quiz, status: :cancelled})
      game_session_fixture(%{quiz: quiz, status: :waiting})

      assert QuizLock.locked?(quiz.id)
    end

    test "ignora a sala ativa de outro quiz", %{scope: scope, quiz: quiz} do
      other = quiz_fixture(scope, %{title: "Outro quiz"})
      game_session_fixture(%{quiz: other, status: :waiting})

      refute QuizLock.locked?(quiz.id)
    end
  end

  describe "locked_ids/1" do
    test "devolve só os quizzes com sala ativa", %{scope: scope, quiz: locked} do
      released = quiz_fixture(scope, %{title: "Liberado"})
      never_played = quiz_fixture(scope, %{title: "Nunca jogado"})

      game_session_fixture(%{quiz: locked, status: :in_progress})
      game_session_fixture(%{quiz: released, status: :expired})

      ids = [locked.id, released.id, never_played.id]

      assert QuizLock.locked_ids(ids) == MapSet.new([locked.id])
    end

    test "resolve em uma única consulta, qualquer que seja o tamanho da lista", %{scope: scope} do
      quizzes = for index <- 1..10, do: quiz_fixture(scope, %{title: "Quiz #{index}"})
      for quiz <- quizzes, do: game_session_fixture(%{quiz: quiz, status: :waiting})

      ids = Enum.map(quizzes, & &1.id)

      assert count_queries(fn -> QuizLock.locked_ids(ids) end) == 1
    end

    test "não repete o id de um quiz com mais de uma sala ativa", %{quiz: quiz} do
      game_session_fixture(%{quiz: quiz, status: :waiting})
      game_session_fixture(%{quiz: quiz, status: :in_progress})

      assert QuizLock.locked_ids([quiz.id]) == MapSet.new([quiz.id])
    end

    test "devolve um conjunto vazio para uma lista vazia" do
      assert count_queries(fn -> assert QuizLock.locked_ids([]) == MapSet.new() end) == 0
    end

    test "devolve um conjunto vazio quando nenhum id está bloqueado", %{quiz: quiz} do
      assert QuizLock.locked_ids([quiz.id]) == MapSet.new()
    end
  end

  describe "with_lock_flag/1" do
    test "marca o campo virtual sem consulta por linha", %{scope: scope, quiz: locked} do
      released = quiz_fixture(scope, %{title: "Liberado"})
      game_session_fixture(%{quiz: locked, status: :waiting})

      query = from q in Quiz, as: :quiz, where: q.owner_id == ^scope.user.id

      flags =
        query
        |> QuizLock.with_lock_flag()
        |> Repo.all()
        |> Map.new(&{&1.id, &1.locked?})

      assert flags[locked.id] == true
      assert flags[released.id] == false
    end
  end

  describe "lock_quiz!/1" do
    test "devolve o id do quiz travado", %{quiz: quiz} do
      assert Repo.transaction(fn -> QuizLock.lock_quiz!(quiz.id) end) == {:ok, quiz.id}
    end

    test "levanta quando o quiz não existe" do
      assert_raise Ecto.NoResultsError, fn ->
        Repo.transaction(fn -> QuizLock.lock_quiz!(-1) end)
      end
    end
  end

  # Counts only the queries issued by this test process, so a concurrent async
  # test cannot inflate the number.
  defp count_queries(fun) do
    parent = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:live_quiz, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == parent, do: send(parent, {ref, :query})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    drain(ref, 0)
  end

  defp drain(ref, count) do
    receive do
      {^ref, :query} -> drain(ref, count + 1)
    after
      0 -> count
    end
  end
end
