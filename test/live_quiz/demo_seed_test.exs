defmodule LiveQuiz.DemoSeedTest do
  @moduledoc """
  The demonstration data, and the two promises it makes.

  It moved out of `priv/repo/seeds.exs` and into application code so that an
  assembled release could run it (#156), which is also what made it code that
  nothing exercised. The promises worth holding it to are the two the demo
  depends on: it only runs when something asks, and running it twice leaves the
  same data rather than a second copy of everything.
  """

  use LiveQuiz.DataCase, async: false

  alias LiveQuiz.Accounts
  alias LiveQuiz.DemoSeed
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Quizzes.Question
  alias LiveQuiz.Quizzes.Quiz

  describe "o portão" do
    test "está fechado quando ninguém pede" do
      refute DemoSeed.enabled?()
      assert DemoSeed.env_var() == "DEMO_SEED"
    end

    test "abre só com o valor exato" do
      for value <- ["true", "TRUE", " true "] do
        with_env(value, fn -> assert DemoSeed.enabled?() end)
      end

      for value <- ["", "false", "1", "yes", "sim"] do
        with_env(value, fn -> refute DemoSeed.enabled?() end)
      end
    end

    test "run/0 não escreve nada com o portão fechado" do
      assert DemoSeed.run() == :disabled
      assert Repo.aggregate(Quiz, :count) == 0
      assert Repo.aggregate(Accounts.User, :count) == 0
    end

    test "run/0 escreve quando o portão está aberto" do
      with_env("true", fn ->
        assert capture_seed(&DemoSeed.run/0) == :ok
      end)

      assert Accounts.get_user_by_email("demo@livequiz.dev")
    end
  end

  describe "os dados da demonstração" do
    setup do
      capture_seed(&DemoSeed.run!/0)
      :ok
    end

    test "criam as duas contas documentadas, já confirmadas" do
      for email <- ["demo@livequiz.dev", "partida@livequiz.dev"] do
        user = Accounts.get_user_by_email(email)

        assert user, "a conta #{email} não foi criada"
        assert user.confirmed_at, "a conta #{email} ficou por confirmar"

        # A senha documentada tem de entrar: é o que a release publica nas notas.
        assert Accounts.get_user_by_email_and_password(email, "demo123456789")
      end
    end

    test "criam as três salas que a demonstração mostra" do
      for code <- ~w(DEMA25 FECHA4 JGAND3) do
        assert Repo.get_by(GameSession, join_code: code), "faltou a sala #{code}"
      end
    end

    test "a sala em espera tem gente e nenhuma pergunta aberta" do
      waiting = Repo.get_by!(GameSession, join_code: "DEMA25")

      assert waiting.status == :waiting
      assert Repo.aggregate(participants_of(waiting), :count) == 3
    end

    test "a partida em andamento está numa pergunta aberta" do
      playing = Repo.get_by!(GameSession, join_code: "JGAND3")

      assert playing.status == :in_progress
      assert playing.current_question_position
      assert is_nil(playing.current_question_closed_at)
    end

    test "a partida encerrada tem resultado congelado" do
      finished = Repo.get_by!(GameSession, join_code: "FECHA4")

      assert finished.status == :finished
      assert Repo.aggregate(participants_of(finished), :count) == 3
    end
  end

  describe "rodar duas vezes" do
    test "deixa os mesmos dados, nunca uma segunda cópia" do
      capture_seed(&DemoSeed.run!/0)

      before = counts()

      capture_seed(&DemoSeed.run!/0)

      assert counts() == before
    end
  end

  defp counts do
    %{
      users: Repo.aggregate(Accounts.User, :count),
      quizzes: Repo.aggregate(Quiz, :count),
      questions: Repo.aggregate(Question, :count),
      sessions: Repo.aggregate(GameSession, :count),
      participants: Repo.aggregate(Participant, :count)
    }
  end

  defp participants_of(%GameSession{id: id}),
    do: where(Participant, [p], p.game_session_id == ^id)

  # O seed conversa com quem o roda pelo `IO.puts`. A suíte não precisa ouvir.
  defp capture_seed(fun) do
    ExUnit.CaptureIO.capture_io(fn -> send(self(), {:result, fun.()}) end)

    receive do
      {:result, result} -> result
    end
  end

  defp with_env(value, fun) do
    previous = System.get_env(DemoSeed.env_var())
    System.put_env(DemoSeed.env_var(), value)

    try do
      fun.()
    after
      if previous,
        do: System.put_env(DemoSeed.env_var(), previous),
        else: System.delete_env(DemoSeed.env_var())
    end
  end
end
