defmodule LiveQuiz.Games.QuestionTimerTest do
  # O timer é um processo à parte que lê e escreve a partida, então a sandbox
  # precisa ser compartilhada com ele.
  use LiveQuiz.DataCase, async: false

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.QuestionTimer
  alias LiveQuiz.Games.QuestionTimerSupervisor

  describe "configuração" do
    test "o agendamento automático fica desligado na suíte" do
      refute QuestionTimer.enabled?()
    end

    test "o registro e o supervisor sobem com a aplicação" do
      assert is_pid(Process.whereis(LiveQuiz.Games.QuestionTimerRegistry))
      assert is_pid(Process.whereis(QuestionTimerSupervisor))
    end
  end

  describe "ensure_started/1" do
    setup :open_match

    test "o avanço deixa a partida com um timer armado", %{session: session} do
      assert is_pid(QuestionTimer.whereis(session.id))
    end

    test "cria um único processo por partida e é idempotente", %{session: session} do
      pid = QuestionTimer.whereis(session.id)

      assert {:ok, ^pid} = QuestionTimer.ensure_started(session)
      assert {:ok, ^pid} = QuestionTimer.ensure_started(session)
      assert QuestionTimer.whereis(session.id) == pid
    end

    test "o timer guarda a posição e o prazo da pergunta", %{session: session} do
      state = :sys.get_state(QuestionTimer.whereis(session.id))

      assert state.session_id == session.id
      assert state.position == 1
      assert state.ends_at == session.current_question_ends_at
    end

    test "a partida sem pergunta aberta não ganha timer" do
      %{session: session} = running_match(%{})

      assert QuestionTimer.ensure_started(session) == {:error, :no_open_question}
      assert is_nil(QuestionTimer.whereis(session.id))
    end

    test "a partida com a pergunta já encerrada não ganha timer", %{
      scope: scope,
      session: session
    } do
      assert {:ok, closed} = Games.close_question(scope, session)

      assert QuestionTimer.ensure_started(closed) == {:error, :no_open_question}
      assert is_nil(QuestionTimer.whereis(session.id))
    end
  end

  describe "stop/1 e whereis/1" do
    setup :open_match

    test "derruba o timer da partida", %{session: session} do
      pid = QuestionTimer.whereis(session.id)

      assert QuestionTimer.stop(session.id) == :ok
      refute Process.alive?(pid)
      assert is_nil(QuestionTimer.whereis(session.id))
    end

    test "é idempotente", %{session: session} do
      assert QuestionTimer.stop(session.id) == :ok
      assert QuestionTimer.stop(session.id) == :ok
    end

    test "a partida sem timer nenhum devolve :ok" do
      %{session: session} = running_match(%{})

      assert QuestionTimer.stop(session.id) == :ok
      assert is_nil(QuestionTimer.whereis(session.id))
    end
  end

  describe "fire_now/1" do
    setup :open_match

    test "a partida sem timer devolve {:error, :not_found}" do
      %{session: session} = running_match(%{})

      assert QuestionTimer.fire_now(session.id) == {:error, :not_found}
    end

    test "o prazo vencido encerra a pergunta e publica o evento uma vez", %{session: session} do
      overdue(session)
      :ok = Games.subscribe(session.id)
      pid = QuestionTimer.whereis(session.id)

      assert QuestionTimer.fire_now(session.id) == :ok
      await_stop(pid)

      assert_receive {:question_closed, %GameSession{current_question_position: 1}}, 1_000
      refute_receive {:question_closed, _repeated}, 100

      refute is_nil(reload(session).current_question_closed_at)
    end

    test "o prazo ainda em curso não encerra nada e mantém o timer", %{session: session} do
      :ok = Games.subscribe(session.id)

      assert QuestionTimer.fire_now(session.id) == :ok

      assert Process.alive?(QuestionTimer.whereis(session.id))
      assert is_nil(reload(session).current_question_closed_at)
      refute_receive {:question_closed, _nothing}, 100
    end

    test "a pergunta já encerrada não tem o instante reescrito", %{
      scope: scope,
      session: session
    } do
      assert {:ok, closed} = Games.close_question(scope, session)
      # O encerramento do host já derrubou o timer; o de agora é armado à mão,
      # ainda acreditando na pergunta aberta que o host acabou de fechar.
      assert {:ok, pid} = QuestionTimer.ensure_started(overdue_struct(session))
      :ok = Games.subscribe(session.id)

      assert QuestionTimer.fire_now(session.id) == :ok
      await_stop(pid)

      assert reload(session).current_question_closed_at == closed.current_question_closed_at
      refute_receive {:question_closed, _repeated}, 100
    end

    test "o timer atrasado não encerra a pergunta seguinte", %{scope: scope, session: session} do
      assert {:ok, second} = Games.advance_question(scope, session, 1)
      :ok = QuestionTimer.stop(second.id)
      # Um timer que ainda acredita estar na pergunta 1, com o prazo dela vencido
      # há muito, enquanto a partida já está na 2.
      assert {:ok, pid} = QuestionTimer.ensure_started(overdue_struct(session))
      :ok = Games.subscribe(session.id)

      assert QuestionTimer.fire_now(session.id) == :ok
      await_stop(pid)

      current = reload(session)
      assert current.current_question_position == 2
      assert is_nil(current.current_question_closed_at)
      refute_receive {:question_closed, _nothing}, 100
    end

    test "a partida encerrada apaga o timer sem tocar em nada", %{
      scope: scope,
      session: session
    } do
      overdue(session)
      assert {:ok, cancelled} = Games.cancel_game_session(scope, session)
      assert {:ok, pid} = QuestionTimer.ensure_started(overdue_struct(session))

      assert QuestionTimer.fire_now(session.id) == :ok
      await_stop(pid)

      current = reload(session)
      assert current.status == :cancelled
      assert current.finished_at == cancelled.finished_at
      assert is_nil(current.current_question_closed_at)
    end

    test "a partida que sumiu do banco apaga o timer", %{session: session} do
      pid = QuestionTimer.whereis(session.id)
      Repo.delete_all(from s in GameSession, where: s.id == ^session.id)

      assert QuestionTimer.fire_now(session.id) == :ok
      await_stop(pid)
    end
  end

  describe "a mensagem agendada" do
    setup :open_match

    test "a mensagem que chega antes do prazo não encerra nada e mantém o timer", %{
      session: session
    } do
      pid = QuestionTimer.whereis(session.id)
      :ok = Games.subscribe(session.id)

      send(pid, :check)
      assert :sys.get_state(pid).position == 1

      assert Process.alive?(pid)
      assert is_nil(reload(session).current_question_closed_at)
      refute_receive {:question_closed, _nothing}, 100
    end

    test "a mensagem que chega depois do prazo encerra a pergunta e o processo", %{
      session: session
    } do
      overdue(session)
      pid = QuestionTimer.whereis(session.id)
      :ok = Games.subscribe(session.id)

      send(pid, :check)

      assert_receive {:question_closed, %GameSession{}}, 1_000
      await_stop(pid)
    end

    test "a pergunta sem prazo no banco não é encerrada", %{session: session} do
      session
      |> reload()
      |> Ecto.Changeset.change(%{current_question_ends_at: nil})
      |> Repo.update!()

      pid = QuestionTimer.whereis(session.id)

      assert QuestionTimer.fire_now(session.id) == :ok
      assert Process.alive?(pid)
      assert is_nil(reload(session).current_question_closed_at)
      assert Games.close_question_by_timeout(session.id) == {:error, :not_due}
    end

    test "o rearme cancela a mensagem anterior e agenda a nova", %{
      scope: scope,
      session: session
    } do
      :ok = QuestionTimer.stop(session.id)
      enable_scheduling()
      assert {:ok, pid} = QuestionTimer.ensure_started(session)
      kill_on_exit(pid)
      first = :sys.get_state(pid).timer

      assert {:ok, second} = Games.advance_question(scope, session, 1)

      state = :sys.get_state(pid)
      assert state.position == 2
      assert state.ends_at == second.current_question_ends_at
      assert state.timer != first
      assert Process.read_timer(first) == false
      assert_in_delta Process.read_timer(state.timer), 30_000, 1_000
    end
  end

  describe "stop/1 de dentro do próprio timer" do
    test "é um no-op, para o processo nunca esperar o próprio desligamento" do
      %{session: session} = running_match(%{})

      {:ok, _owner} =
        Registry.register(
          LiveQuiz.Games.QuestionTimerRegistry,
          {:question_timer, session.id},
          nil
        )

      assert QuestionTimer.whereis(session.id) == self()
      assert QuestionTimer.stop(session.id) == :ok
      assert Process.alive?(self())
    end
  end

  describe "ciclo de vida do timer" do
    setup :open_match

    test "o encerramento pelo host desliga o timer", %{scope: scope, session: session} do
      pid = QuestionTimer.whereis(session.id)

      assert {:ok, _closed} = Games.close_question(scope, session)

      refute Process.alive?(pid)
      assert is_nil(QuestionTimer.whereis(session.id))
    end

    test "o avanço substitui o timer, que passa a valer o prazo da pergunta 2", %{
      scope: scope,
      session: session
    } do
      pid = QuestionTimer.whereis(session.id)

      assert {:ok, second} = Games.advance_question(scope, session, 1)

      assert QuestionTimer.whereis(second.id) == pid
      state = :sys.get_state(pid)
      assert state.position == 2
      assert state.ends_at == second.current_question_ends_at
    end

    test "a última resposta que fecha a pergunta desliga o timer", %{
      session: session,
      questions: questions
    } do
      participant = participant_fixture(session)
      option = option_at(questions, 1, 1)
      pid = QuestionTimer.whereis(session.id)

      assert {:ok, %{closed?: true}} = Games.answer_question(participant, option.id, 1)

      refute Process.alive?(pid)
      assert is_nil(QuestionTimer.whereis(session.id))
    end

    test "finalizar a partida desliga o timer", %{scope: scope, session: session} do
      pid = QuestionTimer.whereis(session.id)

      assert {:ok, _finished} = Games.finish_game_session(scope, session)

      refute Process.alive?(pid)
      assert is_nil(QuestionTimer.whereis(session.id))
    end

    test "cancelar a sala desliga o timer", %{scope: scope, session: session} do
      pid = QuestionTimer.whereis(session.id)

      assert {:ok, _cancelled} = Games.cancel_game_session(scope, session)

      refute Process.alive?(pid)
      assert is_nil(QuestionTimer.whereis(session.id))
    end

    test "expirar a sala desliga o timer", %{session: session} do
      pid = QuestionTimer.whereis(session.id)

      assert {:ok, _expired} = Games.expire_game_session(session)

      refute Process.alive?(pid)
      assert is_nil(QuestionTimer.whereis(session.id))
    end

    test "a queda do host não desliga o timer nem estende o prazo", %{session: session} do
      pid = QuestionTimer.whereis(session.id)

      assert {:ok, away} = Games.mark_host_disconnected(session)

      assert Process.alive?(pid)
      assert away.current_question_ends_at == session.current_question_ends_at
    end

    test "a morte forçada do timer não derruba o supervisor nem a partida", %{session: session} do
      supervisor = Process.whereis(QuestionTimerSupervisor)
      pid = QuestionTimer.whereis(session.id)

      Process.exit(pid, :kill)
      await_stop(pid)

      assert Process.alive?(supervisor)

      current = reload(session)
      assert current.status == :in_progress
      # O prazo nunca esteve só na memória: continua no banco, à espera da
      # varredura de subida.
      assert current.current_question_ends_at == session.current_question_ends_at
    end
  end

  describe "encerramento por tempo sob concorrência" do
    setup :open_match

    test "o timer e o host encerrando juntos produzem um evento só", %{
      scope: scope,
      session: session
    } do
      overdue(session)
      :ok = Games.subscribe(session.id)

      results =
        in_parallel([:timer, :host], fn
          :timer -> Games.close_question_by_timeout(session.id)
          :host -> Games.close_question(scope, session)
        end)

      assert Enum.all?(results, &match?({:ok, %GameSession{}}, &1))

      closed_at = reload(session).current_question_closed_at
      refute is_nil(closed_at)
      assert Enum.all?(results, fn {:ok, s} -> s.current_question_closed_at == closed_at end)

      assert_receive {:question_closed, %GameSession{}}, 1_000
      refute_receive {:question_closed, _repeated}, 100
    end

    test "o timer e a última resposta juntos, com o prazo vencido, produzem um evento só", %{
      session: session,
      questions: questions
    } do
      participant = participant_fixture(session)
      option = option_at(questions, 1, 1)
      overdue(session)
      :ok = Games.subscribe(session.id)

      assert [{:ok, %GameSession{}}, {:error, reason}] =
               in_parallel([:timer, :answer], fn
                 :timer -> Games.close_question_by_timeout(session.id)
                 :answer -> Games.answer_question(participant, option.id, 1)
               end)

      # A resposta chegou depois do prazo, então o encerramento é do timer.
      assert reason in [:time_is_up, :question_closed]
      refute is_nil(reload(session).current_question_closed_at)

      assert_receive {:question_closed, %GameSession{}}, 1_000
      refute_receive {:question_closed, _repeated}, 100
    end

    test "a última resposta e o timer juntos, com o prazo em curso, produzem um evento só", %{
      session: session,
      questions: questions
    } do
      participant = participant_fixture(session)
      option = option_at(questions, 1, 1)
      :ok = Games.subscribe(session.id)

      assert [{:error, :not_due}, {:ok, %{closed?: true}}] =
               in_parallel([:timer, :answer], fn
                 :timer -> Games.close_question_by_timeout(session.id)
                 :answer -> Games.answer_question(participant, option.id, 1)
               end)

      refute is_nil(reload(session).current_question_closed_at)

      assert_receive {:question_closed, %GameSession{}}, 1_000
      refute_receive {:question_closed, _repeated}, 100
    end

    test "dois disparos simultâneos registram um instante só", %{session: session} do
      overdue(session)
      :ok = Games.subscribe(session.id)

      results =
        in_parallel([1, 2], fn _attempt -> Games.close_question_by_timeout(session.id) end)

      assert [{:ok, %GameSession{} = first}, {:ok, %GameSession{} = second}] = results
      assert first.current_question_closed_at == second.current_question_closed_at

      assert_receive {:question_closed, %GameSession{}}, 1_000
      refute_receive {:question_closed, _repeated}, 100
    end
  end

  describe "prazo que vence sozinho" do
    setup :open_match

    test "a pergunta é encerrada quando o prazo vence, sem ninguém pedir", %{session: session} do
      :ok = QuestionTimer.stop(session.id)
      ending = ending_in(session, 150)
      :ok = Games.subscribe(session.id)

      assert {:ok, pid} = QuestionTimerSupervisor.start_timer(ending, enabled: true)
      kill_on_exit(pid)

      assert_receive {:question_closed, %GameSession{current_question_position: 1}}, 3_000
      refute_receive {:question_closed, _repeated}, 100

      refute is_nil(reload(session).current_question_closed_at)
    end

    test "o prazo vence com o host fora e a partida continua na pergunta 1", %{
      session: session
    } do
      assert {:ok, away} = Games.mark_host_disconnected(session)
      :ok = QuestionTimer.stop(session.id)
      ending = ending_in(away, 150)
      :ok = Games.subscribe(session.id)

      assert {:ok, pid} = QuestionTimerSupervisor.start_timer(ending, enabled: true)
      kill_on_exit(pid)

      assert_receive {:question_closed, %GameSession{}}, 3_000

      current = reload(session)
      assert current.status == :in_progress
      assert current.current_question_position == 1
      refute is_nil(current.current_question_closed_at)
    end

    test "o prazo já vencido no momento do agendamento não vira intervalo negativo", %{
      session: session
    } do
      :ok = QuestionTimer.stop(session.id)
      overdue(session)
      :ok = Games.subscribe(session.id)

      assert {:ok, pid} =
               QuestionTimerSupervisor.start_timer(overdue_struct(session), enabled: true)

      kill_on_exit(pid)

      assert_receive {:question_closed, %GameSession{}}, 3_000
    end
  end

  describe "integração: a partida inteira encerrada por tempo" do
    test "as três perguntas de dez segundos são encerradas na ordem" do
      scope = user_scope_fixture()

      session =
        game_session_fixture(%{
          host: scope.user,
          status: :in_progress,
          question_duration_seconds: 10
        })

      snapshot_fixture(session, count: 3)
      :ok = Games.subscribe(session.id)

      closed =
        Enum.reduce(1..3, {session, []}, fn position, {current, acc} ->
          expected = if position == 1, do: nil, else: position - 1
          assert {:ok, open} = Games.advance_question(scope, current, expected)
          assert open.current_question_position == position

          assert DateTime.diff(open.current_question_ends_at, open.current_question_started_at) ==
                   10

          overdue(open)
          assert QuestionTimer.fire_now(session.id) == :ok

          assert_receive {:question_closed, %GameSession{current_question_position: ^position}},
                         1_000

          {reload(open), [position | acc]}
        end)

      assert closed |> elem(1) |> Enum.reverse() == [1, 2, 3]
      assert is_nil(QuestionTimer.whereis(session.id))
    end
  end

  defp running_match(_context) do
    scope = user_scope_fixture()
    session = game_session_fixture(%{host: scope.user, status: :in_progress})

    %{scope: scope, session: session, questions: snapshot_fixture(session, count: 3)}
  end

  defp open_match(context) do
    %{scope: scope, session: session} = match = running_match(context)
    {:ok, open} = Games.advance_question(scope, session, nil)
    on_exit(fn -> QuestionTimer.stop(open.id) end)

    %{match | session: open}
  end

  # O prazo é escrito pelo contexto a partir da duração da sala, então um teste
  # que precisa dele já vencido recua o início da pergunta.
  defp overdue(%GameSession{} = session), do: ending_in(session, -5_000)

  # A mesma partida, sem tocar no banco: é o que um timer atrasado tem em mãos.
  defp overdue_struct(%GameSession{} = session) do
    %{session | current_question_ends_at: DateTime.add(now_usec(), -5, :second)}
  end

  defp ending_in(%GameSession{} = session, milliseconds) do
    started_at =
      now_usec()
      |> DateTime.add(milliseconds, :millisecond)
      |> DateTime.add(-session.question_duration_seconds, :second)

    session
    |> reload()
    |> Ecto.Changeset.change(%{
      current_question_started_at: started_at,
      current_question_ends_at:
        DateTime.add(started_at, session.question_duration_seconds, :second)
    })
    |> Repo.update!()
  end

  defp option_at(questions, question_position, option_position) do
    questions
    |> Enum.find(&(&1.position == question_position))
    |> Map.fetch!(:answer_options)
    |> Enum.find(&(&1.position == option_position))
  end

  defp await_stop(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
  end

  # Os timers da suíte não se agendam sozinhos; o teste que quer medir o
  # intervalo armado liga o agendamento só para si.
  defp enable_scheduling do
    previous = Application.get_env(:live_quiz, QuestionTimer, [])
    Application.put_env(:live_quiz, QuestionTimer, Keyword.put(previous, :enabled, true))
    on_exit(fn -> Application.put_env(:live_quiz, QuestionTimer, previous) end)
  end

  defp kill_on_exit(pid) do
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
  end

  defp reload(%GameSession{id: id}), do: Repo.get!(GameSession, id)

  defp in_parallel(items, fun) do
    owner = self()

    items
    |> Enum.map(fn item ->
      Task.async(fn ->
        Sandbox.allow(Repo, owner, self())
        fun.(item)
      end)
    end)
    |> Task.await_many(30_000)
  end
end
