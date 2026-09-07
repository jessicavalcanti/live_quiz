defmodule LiveQuiz.Games.HostAbsenceReconciliationTest do
  @moduledoc """
  An absence the monitor's memory lost, and a confirmation that belongs to a
  window nobody is waiting on any more.

  Regressions for R20 and R21 of the review. Presence is memory and the
  deadline is a row: a restart drops the first and keeps the second, which is
  how a room could end up abandoned with no deadline behind it and no sweeper
  ever finding it.
  """

  use LiveQuiz.DataCase, async: false

  import ExUnit.CaptureLog
  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures

  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.HostMonitor
  alias LiveQuiz.Games.Presence

  @grace 100

  setup :own_monitor

  describe "configuração" do
    test "o tique é de trinta segundos" do
      assert HostMonitor.tick() == :timer.seconds(30)
    end

    test "a reconciliação periódica fica desligada na suíte" do
      refute HostMonitor.enabled?()
    end
  end

  describe "reconciliação de presença" do
    setup :claimed_room

    test "abre uma janela para a sala cujo host sumiu sem deixar prazo", context do
      %{monitor: monitor, session: session} = context

      # O estado que um reinício deixa: a sala guarda a conexão do host, mas não
      # há presença nenhuma e `expires_at` continua nulo — ninguém chegou a
      # persistir a ausência, então o sweeper nunca acharia esta sala.
      assert is_nil(reload(session).expires_at)

      assert %{opened: 1, cleared: 0} = HostMonitor.reconcile_now(monitor)

      assert_receive {:host_disconnected, expires_at}, @grace * 10
      assert reload(session).expires_at == expires_at
    end

    test "não abre uma segunda janela para a sala que já tem uma", context do
      %{monitor: monitor, session: session} = context

      assert %{opened: 1} = HostMonitor.reconcile_now(monitor)
      assert %{opened: 0, cleared: 0} = HostMonitor.reconcile_now(monitor)

      assert_receive {:host_disconnected, _expires_at}, @grace * 10
      assert reload(session).expires_at
    end

    test "não toca na sala cujo host está presente", context do
      %{monitor: monitor, session: session} = context
      connect_host(session)

      assert %{opened: 0, cleared: 0} = HostMonitor.reconcile_now(monitor)

      refute_receive {:host_disconnected, _expires_at}, @grace * 3
      assert is_nil(reload(session).expires_at)
    end

    test "derruba o prazo herdado quando o host está presente", context do
      %{monitor: monitor, session: session} = context
      connect_host(session)
      {:ok, away} = Games.mark_host_disconnected(session, now())
      assert away.expires_at

      assert %{cleared: 1, opened: 0} = HostMonitor.reconcile_now(monitor)

      assert_receive {:host_connected, nil}, @grace * 10
      assert is_nil(reload(session).expires_at)
    end

    test "deixa em paz a sala que nunca teve conexão de host", context do
      %{monitor: monitor, session: claimed} = context
      rest_only = game_session_fixture(%{status: :waiting})

      # Sala aberta pela API e nunca reivindicada de um socket: não há presença
      # com que comparar, e ler a presença vazia como ausência expiraria uma
      # sala cujo host a conduz por HTTP. A sala reivindicada ao lado dela é a
      # prova de que a varredura rodou.
      assert %{opened: 1, cleared: 0} = HostMonitor.reconcile_now(monitor)

      assert_receive {:host_disconnected, _expires_at}, @grace * 10
      assert reload(claimed).expires_at
      assert is_nil(reload(rest_only).expires_at)
    end

    test "ignora a sala já encerrada", context do
      %{monitor: monitor, scope: scope, session: session} = context
      {:ok, _cancelled} = Games.cancel_game_session(scope, session)

      assert %{opened: 0, cleared: 0} = HostMonitor.reconcile_now(monitor)
    end
  end

  describe "tolerância a falha da reconciliação" do
    test "uma listagem que explode é registrada e o monitor continua vivo" do
      {:ok, monitor} =
        HostMonitor.start_link(
          name: nil,
          grace_period: @grace,
          lister: fn -> raise "banco fora" end
        )

      on_exit(fn -> if Process.alive?(monitor), do: GenServer.stop(monitor) end)

      log =
        capture_log(fn ->
          assert %{opened: 0, cleared: 0} = HostMonitor.reconcile_now(monitor)
        end)

      assert log =~ "host presence reconciliation failed listing"
      assert Process.alive?(monitor)
    end
  end

  describe "referência do ciclo de ausência" do
    setup :claimed_room

    test "a confirmação de uma janela cancelada não aplica a carência errada", context do
      %{monitor: monitor, session: session} = context

      # Cai, volta, cai de novo. A confirmação da primeira janela já está na
      # mailbox quando a segunda é registrada.
      HostMonitor.host_disconnected(session.id, monitor)
      first = cycle_of(monitor, session.id)

      HostMonitor.host_connected(session.id, monitor)
      HostMonitor.host_disconnected(session.id, monitor)
      second = cycle_of(monitor, session.id)

      refute first == second

      send(monitor, {:confirm_absence, session.id, first})
      _settled = :sys.get_state(monitor)

      # A mensagem antiga não persistiu ausência nenhuma e, sobretudo, não
      # apagou a janela nova: é ela quem ainda vai decidir.
      assert is_nil(reload(session).expires_at)
      assert cycle_of(monitor, session.id) == second
    end

    test "a confirmação da janela vigente persiste a ausência", context do
      %{monitor: monitor, session: session} = context

      HostMonitor.host_disconnected(session.id, monitor)
      cycle = cycle_of(monitor, session.id)

      send(monitor, {:confirm_absence, session.id, cycle})
      _settled = :sys.get_state(monitor)

      assert reload(session).expires_at
      assert is_nil(cycle_of(monitor, session.id))
    end

    test "uma confirmação de sala que não tem janela nenhuma é inócua", context do
      %{monitor: monitor, session: session} = context

      send(monitor, {:confirm_absence, session.id, make_ref()})
      _settled = :sys.get_state(monitor)

      assert is_nil(reload(session).expires_at)
    end
  end

  defp claimed_room(_context) do
    host = user_fixture()
    scope = LiveQuiz.Accounts.Scope.for_user(host)
    session = game_session_fixture(%{host: host, status: :waiting})
    {:ok, session, _connection_id} = Games.claim_host_connection(scope, session)
    :ok = Games.subscribe(session.id)

    %{scope: scope, session: session}
  end

  defp own_monitor(_context) do
    {:ok, monitor} = HostMonitor.start_link(name: nil, grace_period: @grace)
    Application.put_env(:live_quiz, :host_monitor, monitor)

    on_exit(fn ->
      Application.delete_env(:live_quiz, :host_monitor)
      if Process.alive?(monitor), do: GenServer.stop(monitor)
    end)

    %{monitor: monitor}
  end

  defp cycle_of(monitor, session_id) do
    case :sys.get_state(monitor).pending[session_id] do
      {cycle, _timer} -> cycle
      nil -> nil
    end
  end

  # A presença é anunciada por um processo e lida por outro, então esperar o
  # aviso não garante que a leitura já a enxergue. O que o teste precisa é do
  # estado que ele vai afirmar, e é por ele que se espera.
  defp connect_host(session) do
    {:ok, pid} = Agent.start(fn -> :connected end)
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)

    {:ok, _ref} = Presence.track_host(pid, session, session.host_connection_id)
    assert_receive {:presence_changed, _session_id}, 2_000

    assert eventually(fn -> Presence.host_in_control?(reload(session)) end),
           "a presença do host não ficou visível"

    pid
  end

  defp eventually(check, attempts \\ 200)
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
