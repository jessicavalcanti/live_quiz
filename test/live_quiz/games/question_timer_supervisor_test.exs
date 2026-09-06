defmodule LiveQuiz.Games.QuestionTimerSupervisorTest do
  # A varredura corre fora do processo do teste e ainda arma timers que leem a
  # partida, então a sandbox precisa ser compartilhada.
  use LiveQuiz.DataCase, async: false

  import ExUnit.CaptureLog
  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures

  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.QuestionTimer
  alias LiveQuiz.Games.QuestionTimerSupervisor

  describe "recover/0" do
    test "encerra a pergunta cujo prazo venceu durante a indisponibilidade" do
      # A aplicação teria caído às 09h58 e voltado às 10h05: o prazo venceu às
      # 10h00, com a aplicação fora do ar, e a pergunta não ganha tempo novo.
      %{session: session} = match_stopped_on_question(-30 * 60)
      :ok = Games.subscribe(session.id)
      before = DateTime.utc_now()

      assert %{closed: 1, scheduled: 0} = QuestionTimerSupervisor.recover()

      closed = reload(session)
      refute is_nil(closed.current_question_closed_at)
      # O encerramento acontece agora, mas o prazo continua sendo o de trinta
      # minutos atrás: a queda não empurrou o relógio da pergunta.
      assert DateTime.compare(closed.current_question_ends_at, before) == :lt

      assert DateTime.compare(closed.current_question_closed_at, closed.current_question_ends_at) ==
               :gt

      assert_receive {:question_closed, %GameSession{}}, 1_000
    end

    test "a partida encerrada por tempo continua in_progress, na mesma pergunta" do
      %{session: session} = match_stopped_on_question(-30 * 60)

      assert %{closed: 1} = QuestionTimerSupervisor.recover()

      current = reload(session)
      assert current.status == :in_progress
      assert current.current_question_position == 1
    end

    test "agenda o restante do prazo da pergunta que ainda está em curso" do
      %{session: session} = match_stopped_on_question(20)

      assert %{closed: 0, scheduled: 1} = QuestionTimerSupervisor.recover()

      pid = QuestionTimer.whereis(session.id)
      assert is_pid(pid)
      on_exit(fn -> QuestionTimer.stop(session.id) end)

      state = :sys.get_state(pid)
      assert state.position == 1
      assert state.ends_at == reload(session).current_question_ends_at

      # Vinte segundos restantes de um prazo de trinta: o timer é armado com o
      # que sobrou, nunca com a duração cheia.
      remaining = DateTime.diff(state.ends_at, DateTime.utc_now(), :millisecond)
      assert_in_delta remaining, 20_000, 1_000
      assert is_nil(reload(session).current_question_closed_at)
    end

    test "o timer agendado pela recuperação conta o que resta, não a duração cheia" do
      %{session: session} = match_stopped_on_question(20)
      enable_scheduling()

      assert %{scheduled: 1} = QuestionTimerSupervisor.recover()

      pid = QuestionTimer.whereis(session.id)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

      armed = pid |> :sys.get_state() |> Map.fetch!(:timer) |> Process.read_timer()
      assert_in_delta armed, 20_000, 1_000
      assert armed < 30_000
    end

    test "ignora as partidas finished, cancelled e expired com prazo vencido" do
      closed =
        for status <- [:finished, :cancelled, :expired] do
          %{session: session} = match_stopped_on_question(-30 * 60)

          session
          |> reload()
          |> Ecto.Changeset.change(%{status: status, finished_at: now()})
          |> Repo.update!()
        end

      assert QuestionTimerSupervisor.recover() == %{closed: 0, scheduled: 0}

      for session <- closed do
        current = reload(session)
        assert current.status == session.status
        assert is_nil(current.current_question_closed_at)
        assert is_nil(QuestionTimer.whereis(session.id))
      end
    end

    test "ignora a pergunta que já estava encerrada" do
      %{scope: scope, session: session} = match_stopped_on_question(-30 * 60)
      assert {:ok, closed} = Games.close_question(scope, session)

      assert QuestionTimerSupervisor.recover() == %{closed: 0, scheduled: 0}

      assert reload(session).current_question_closed_at == closed.current_question_closed_at
    end

    test "ignora a partida que ainda não avançou para pergunta nenhuma" do
      scope = user_scope_fixture()
      session = game_session_fixture(%{host: scope.user, status: :in_progress})
      snapshot_fixture(session, count: 3)

      assert QuestionTimerSupervisor.recover() == %{closed: 0, scheduled: 0}
      assert is_nil(QuestionTimer.whereis(session.id))
    end

    test "uma varredura sem nada pendente não falha" do
      assert QuestionTimerSupervisor.recover() == %{closed: 0, scheduled: 0}
    end

    test "resolve várias partidas de uma vez" do
      overdue = for _index <- 1..2, do: match_stopped_on_question(-30 * 60).session
      running = for _index <- 1..2, do: match_stopped_on_question(20).session

      assert QuestionTimerSupervisor.recover() == %{closed: 2, scheduled: 2}

      for session <- overdue, do: refute(is_nil(reload(session).current_question_closed_at))

      for session <- running do
        assert is_pid(QuestionTimer.whereis(session.id))
        on_exit(fn -> QuestionTimer.stop(session.id) end)
      end
    end
  end

  describe "recover/1 e a tolerância a falha" do
    test "uma partida que explode não impede as demais nem derruba o supervisor" do
      %{session: session} = match_stopped_on_question(-30 * 60)
      # Uma partida com id inválido faz o encerramento estourar, que é
      # exatamente a falha que a varredura tem de absorver.
      broken = %GameSession{
        id: "partida inexistente",
        status: :in_progress,
        current_question_position: 1,
        current_question_ends_at: DateTime.add(DateTime.utc_now(), -60, :second)
      }

      supervisor = Process.whereis(QuestionTimerSupervisor)

      log =
        capture_log(fn ->
          assert QuestionTimerSupervisor.recover(fn -> [broken, reload(session)] end) ==
                   %{closed: 1, scheduled: 0}
        end)

      assert log =~ "question timer recovery failed recovering match"
      assert Process.alive?(supervisor)
      refute is_nil(reload(session).current_question_closed_at)
    end

    test "uma listagem que explode é registrada e não derruba nada" do
      supervisor = Process.whereis(QuestionTimerSupervisor)

      log =
        capture_log(fn ->
          assert QuestionTimerSupervisor.recover(fn -> raise "banco fora do ar" end) ==
                   %{closed: 0, scheduled: 0}
        end)

      assert log =~ "question timer recovery failed listing the matches with an open question"
      assert Process.alive?(supervisor)
    end
  end

  describe "recover/1 e as partidas que nada resolve" do
    test "a partida que já não pode ser encerrada não entra na conta" do
      %{scope: scope, session: session} = match_stopped_on_question(-30 * 60)
      assert {:ok, _cancelled} = Games.cancel_game_session(scope, session)

      assert QuestionTimerSupervisor.recover(fn -> [session] end) == %{closed: 0, scheduled: 0}
    end

    test "a partida com a pergunta já encerrada não ganha timer" do
      %{scope: scope, session: session} = match_stopped_on_question(20)
      assert {:ok, closed} = Games.close_question(scope, session)

      assert QuestionTimerSupervisor.recover(fn -> [closed] end) == %{closed: 0, scheduled: 0}
      assert is_nil(QuestionTimer.whereis(session.id))
    end

    test "a partida sem prazo nenhum não é tratada como vencida" do
      %{session: session} = match_stopped_on_question(20)
      no_deadline = %{session | current_question_ends_at: nil}

      assert QuestionTimerSupervisor.recover(fn -> [no_deadline] end) == %{
               closed: 0,
               scheduled: 0
             }

      assert is_nil(QuestionTimer.whereis(session.id))
    end
  end

  describe "list_sessions_with_open_question/0" do
    test "lista apenas as partidas em andamento com pergunta aberta" do
      %{session: open} = match_stopped_on_question(20)
      %{session: overdue} = match_stopped_on_question(-30 * 60)
      %{scope: scope, session: closed_question} = match_stopped_on_question(20)
      {:ok, _closed} = Games.close_question(scope, closed_question)
      %{scope: other, session: cancelled} = match_stopped_on_question(20)
      {:ok, _cancelled} = Games.cancel_game_session(other, cancelled)

      waiting = game_session_fixture(%{status: :waiting})

      ids = Enum.map(Games.list_sessions_with_open_question(), & &1.id)

      assert overdue.id in ids
      assert open.id in ids
      refute closed_question.id in ids
      refute cancelled.id in ids
      refute waiting.id in ids
    end

    test "devolve as partidas na ordem do prazo, da mais vencida para a menos" do
      %{session: last} = match_stopped_on_question(20)
      %{session: first} = match_stopped_on_question(-30 * 60)
      %{session: middle} = match_stopped_on_question(-60)

      ids = Enum.map(Games.list_sessions_with_open_question(), & &1.id)

      assert Enum.filter(ids, &(&1 in [first.id, middle.id, last.id])) ==
               [first.id, middle.id, last.id]
    end
  end

  # Uma partida parada na pergunta 1, com o prazo posicionado `offset` segundos
  # a partir de agora: negativo o bastante e a pergunta está vencida.
  defp match_stopped_on_question(offset_seconds) do
    scope = user_scope_fixture()
    session = game_session_fixture(%{host: scope.user, status: :in_progress})
    questions = snapshot_fixture(session, count: 3)
    {:ok, open} = Games.advance_question(scope, session, nil)

    ends_at = DateTime.add(now_usec(), offset_seconds, :second)

    stopped =
      open
      |> Ecto.Changeset.change(%{
        current_question_started_at:
          DateTime.add(ends_at, -open.question_duration_seconds, :second),
        current_question_ends_at: ends_at
      })
      |> Repo.update!()

    # O avanço armou um timer com o prazo original; a partida acabou de ser
    # reposicionada, e o que a recuperação encontra é uma aplicação que subiu
    # sem timer nenhum.
    :ok = QuestionTimer.stop(open.id)
    on_exit(fn -> QuestionTimer.stop(open.id) end)

    %{scope: scope, session: stopped, questions: questions}
  end

  # Os timers da suíte não se agendam sozinhos; o teste que quer medir o
  # intervalo armado liga o agendamento só para si.
  defp enable_scheduling do
    previous = Application.get_env(:live_quiz, QuestionTimer, [])
    Application.put_env(:live_quiz, QuestionTimer, Keyword.put(previous, :enabled, true))
    on_exit(fn -> Application.put_env(:live_quiz, QuestionTimer, previous) end)
  end

  defp reload(%GameSession{id: id}), do: Repo.get!(GameSession, id)
end
