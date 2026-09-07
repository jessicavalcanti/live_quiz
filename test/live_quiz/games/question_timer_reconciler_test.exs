defmodule LiveQuiz.Games.QuestionTimerReconcilerTest do
  @moduledoc """
  A question that is open and has nobody timing it.

  Regression for R19 of the review. Timers are temporary on purpose, so one
  that dies for a question that is over must not come back — and the price was
  that one lost for a question that is *not* over came back only at the next
  boot. This is the tick that pays that price down to one interval.
  """

  use LiveQuiz.DataCase, async: false

  import ExUnit.CaptureLog
  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.QuestionTimer
  alias LiveQuiz.Games.QuestionTimerReconciler

  describe "configuração" do
    test "o tique é de quinze segundos" do
      assert QuestionTimerReconciler.tick() == :timer.seconds(15)
    end

    test "a reconciliação periódica fica desligada na suíte" do
      refute QuestionTimerReconciler.enabled?()
    end
  end

  describe "reconcile_now/1" do
    setup [:open_question, :own_reconciler]

    test "rearma a pergunta aberta que perdeu o timer", context do
      %{session: session, reconciler: reconciler} = context
      pid = QuestionTimer.whereis(session.id)
      assert is_pid(pid)

      kill(pid)
      await_unregistered(session.id)

      assert %{armed: 1, closed: 0} = QuestionTimerReconciler.reconcile_now(reconciler)

      assert QuestionTimer.whereis(session.id)
      assert QuestionTimer.timing(session.id) == session.current_question_position
    end

    test "não mexe na pergunta que já tem timer", context do
      %{session: session, reconciler: reconciler} = context
      pid = QuestionTimer.whereis(session.id)

      assert %{armed: 0, closed: 0} = QuestionTimerReconciler.reconcile_now(reconciler)

      assert QuestionTimer.whereis(session.id) == pid
    end

    test "encerra a pergunta cujo prazo venceu sem ninguém fechar", context do
      %{session: session, reconciler: reconciler} = context
      :ok = QuestionTimer.stop(session.id)
      overdue(session)

      assert %{closed: 1, armed: 0} = QuestionTimerReconciler.reconcile_now(reconciler)

      assert reload(session).current_question_closed_at
    end

    test "encerra mesmo quando o timer sobreviveu mas não disparou", context do
      %{session: session, reconciler: reconciler} = context
      overdue(session)

      assert %{closed: 1} = QuestionTimerReconciler.reconcile_now(reconciler)

      assert reload(session).current_question_closed_at
    end

    test "é seguro repetir: a segunda passada não faz nada", context do
      %{session: session, reconciler: reconciler} = context
      :ok = QuestionTimer.stop(session.id)
      overdue(session)

      assert %{closed: 1} = QuestionTimerReconciler.reconcile_now(reconciler)
      assert %{closed: 0, armed: 0} = QuestionTimerReconciler.reconcile_now(reconciler)

      assert reload(session).current_question_closed_at
    end

    test "ignora a partida encerrada", context do
      %{scope: scope, session: session, reconciler: reconciler} = context
      overdue(session)
      {:ok, _finished} = Games.finish_game_session(scope, session)

      assert %{closed: 0, armed: 0} = QuestionTimerReconciler.reconcile_now(reconciler)
    end
  end

  describe "reconcile_now/0" do
    setup :open_question

    test "a varredura padrão encontra a partida com pergunta aberta", %{session: session} do
      kill(QuestionTimer.whereis(session.id))
      await_unregistered(session.id)

      QuestionTimerReconciler.reconcile_now()

      assert QuestionTimer.whereis(session.id)
    end
  end

  describe "quando alguém chega antes" do
    setup :open_question

    test "não conta como encerramento a pergunta que o host já fechou", context do
      %{scope: scope, session: session} = context
      overdue(session)
      stale = reload(session)

      {:ok, _closed} = Games.close_question(scope, session)

      # A listagem viu a pergunta aberta; quando a reconciliação chega, o host já
      # fechou. Não é falha nem trabalho: é o resultado comum de reconciliar ao
      # lado de uma partida saudável.
      reconciler =
        start_supervised!({QuestionTimerReconciler, name: nil, lister: fn -> [stale] end})

      assert %{closed: 0, armed: 0} = QuestionTimerReconciler.reconcile_now(reconciler)
    end

    test "não conta como rearme a partida que já terminou", context do
      %{scope: scope, session: session} = context
      stale = reload(session)
      :ok = QuestionTimer.stop(session.id)
      await_unregistered(session.id)

      {:ok, _finished} = Games.finish_game_session(scope, session)

      reconciler =
        start_supervised!({QuestionTimerReconciler, name: nil, lister: fn -> [stale] end})

      assert %{closed: 0, armed: 0} = QuestionTimerReconciler.reconcile_now(reconciler)
      refute QuestionTimer.whereis(session.id)
    end
  end

  describe "tolerância a falha" do
    test "uma partida que explode não interrompe as demais nem derruba o processo" do
      %{session: session} = open_question(%{})
      :ok = QuestionTimer.stop(session.id)
      overdue(session)

      # Uma partida com id inválido faz a consulta de encerramento estourar, que é
      # a falha que a reconciliação tem de absorver. Os demais campos são o que
      # a fazem chegar até a consulta: só uma pergunta aberta e vencida é
      # encerrada, e um struct sem eles seria descartado antes disso.
      broken = %GameSession{
        id: "partida inexistente",
        status: :in_progress,
        current_question_position: 1,
        current_question_closed_at: nil,
        current_question_ends_at: DateTime.add(DateTime.utc_now(), -60, :second)
      }

      reconciler =
        start_supervised!(
          {QuestionTimerReconciler, name: nil, lister: fn -> [broken, reload(session)] end}
        )

      log =
        capture_log(fn ->
          assert %{closed: 1} = QuestionTimerReconciler.reconcile_now(reconciler)
        end)

      assert log =~ "question timer reconciliation failed reconciling match"
      assert Process.alive?(reconciler)
      assert reload(session).current_question_closed_at
    end

    test "uma listagem que explode é registrada e o processo continua vivo" do
      reconciler =
        start_supervised!(
          {QuestionTimerReconciler, name: nil, lister: fn -> raise "banco fora do ar" end}
        )

      log =
        capture_log(fn ->
          assert %{closed: 0, armed: 0} = QuestionTimerReconciler.reconcile_now(reconciler)
        end)

      assert log =~ "question timer reconciliation failed listing"
      assert Process.alive?(reconciler)
    end
  end

  describe "reconciliação periódica" do
    test "o tique configurado rearma sem ninguém pedir" do
      %{session: session} = open_question(%{})
      kill(QuestionTimer.whereis(session.id))
      await_unregistered(session.id)

      start_supervised!({QuestionTimerReconciler, name: nil, enabled: true, tick: 10})

      assert eventually(fn -> QuestionTimer.whereis(session.id) != nil end)
    end
  end

  # Um reconciliador que só enxerga esta partida. A varredura de verdade lista o
  # banco inteiro, e um contador global seria a soma do que outros testes
  # deixaram para trás — o teste ficaria dependente da ordem da suíte.
  defp own_reconciler(%{session: session}) do
    %{
      reconciler:
        start_supervised!(
          {QuestionTimerReconciler, name: nil, lister: fn -> [reload(session)] end}
        )
    }
  end

  defp open_question(_context) do
    host = user_fixture()
    scope = Scope.for_user(host)
    session = game_session_fixture(%{host: host, status: :in_progress})
    snapshot_fixture(session, count: 2)

    {:ok, opened} = Games.advance_question(scope, session, nil)

    %{scope: scope, session: opened}
  end

  defp overdue(%GameSession{id: id}) do
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    Repo.update_all(from(s in GameSession, where: s.id == ^id),
      set: [current_question_started_at: past, current_question_ends_at: past]
    )
  end

  # `:kill` não roda `terminate/2`, então quem devolve a chave é o monitor do
  # `Registry` — e ele a devolve depois do `:DOWN` que este processo recebe.
  # Esperar o processo morrer não basta: é a entrada do registro que precisa
  # sumir antes de a reconciliação poder rearmar.
  defp kill(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 -> flunk("o timer não morreu")
    end
  end

  defp await_unregistered(session_id) do
    assert eventually(fn -> is_nil(QuestionTimer.whereis(session_id)) end),
           "o registro do timer não foi devolvido"
  end

  # Sem `sleep` fixo: a condição é consultada até valer ou até o limite, que é o
  # que faz o teste passar igual numa máquina lenta.
  defp eventually(check, attempts \\ 100)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(10)
      eventually(check, attempts - 1)
    end
  end

  defp reload(%GameSession{id: id}), do: Repo.get!(GameSession, id)
end
