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

      # O nome do teste é a promessa: o EXISTS correlacionado viaja dentro do
      # SELECT, então marcar N quizzes continua custando uma consulta só.
      assert count_queries(fn ->
               query |> QuizLock.with_lock_flag() |> Repo.all()
             end) == 1

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
end
