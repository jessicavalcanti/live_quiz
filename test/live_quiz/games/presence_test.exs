defmodule LiveQuiz.Games.PresenceTest do
  # The presence, the monitor and the rooms live in processes of their own, so
  # the sandbox has to be shared: an async run would lend them no connection.
  use LiveQuiz.DataCase, async: false

  import ExUnit.CaptureLog
  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures

  alias LiveQuiz.Games
  alias LiveQuiz.Games.HostMonitor
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Games.Presence

  @grace 200

  setup :own_monitor

  describe "track_participant/3 e connected_participant_ids/1" do
    setup :waiting_session

    test "uma sala sem ninguém conectado não tem conectados", %{session: session} do
      assert Presence.connected_participant_ids(session.id) == MapSet.new()
      assert Presence.connected_count(session.id) == 0
    end

    test "um participante conectado aparece pelo id", %{session: session} do
      participant = participant_fixture(session)

      connect(participant)

      assert Presence.connected_participant_ids(session.id) == MapSet.new([participant.id])
      assert Presence.connected_count(session.id) == 1
    end

    test "os 25 participantes de uma sala cheia contam 25", %{session: session} do
      participants = for _index <- 1..25, do: participant_fixture(session)

      Enum.each(participants, &connect/1)

      assert Presence.connected_count(session.id) == 25

      assert Presence.connected_participant_ids(session.id) ==
               MapSet.new(participants, & &1.id)
    end

    test "duas abas da mesma participação contam como uma pessoa", %{session: session} do
      participant = participant_fixture(session)

      connect(participant)
      connect(participant)

      assert Presence.connected_count(session.id) == 1
    end

    test "a presença de uma sala não vaza para outra", %{session: session} do
      other_session = game_session_fixture(%{status: :waiting})
      :ok = Games.subscribe(other_session.id)
      other_session |> participant_fixture() |> connect()

      assert Presence.connected_count(session.id) == 0
      assert Presence.connected_count(other_session.id) == 1
    end

    test "quem sai da sala deixa de ser contado", %{session: session} do
      participant = participant_fixture(session)
      connection = connect(participant)

      assert {:ok, _left} = Games.leave_game_session(participant)
      stop_connection(connection)

      assert_receive {:presence_changed, _session_id}, 2_000
      assert Presence.connected_count(session.id) == 0
    end

    test "o host não entra na contagem de participantes", %{session: session} do
      connect_host(session)

      assert Presence.connected_count(session.id) == 0
      assert Presence.host_connected?(session.id)
    end
  end

  describe "host_connected?/1" do
    setup :waiting_session

    test "é falso enquanto ninguém está no tópico", %{session: session} do
      refute Presence.host_connected?(session.id)
    end

    test "é falso quando só há participantes", %{session: session} do
      session |> participant_fixture() |> connect()

      refute Presence.host_connected?(session.id)
    end

    test "é verdadeiro com o host conectado", %{session: session} do
      connect_host(session)

      assert Presence.host_connected?(session.id)
    end
  end

  describe "eventos de presença" do
    setup :waiting_session

    test "a chegada de alguém avisa os inscritos", %{session: session} do
      session |> participant_fixture() |> track()

      assert_receive {:presence_changed, session_id}, 2_000
      assert session_id == session.id
    end

    test "a queda avisa os inscritos e mantém a pessoa na lista", %{session: session} do
      participant = participant_fixture(session)
      connection = connect(participant)

      stop_connection(connection)

      assert_receive {:presence_changed, session_id}, 2_000
      assert session_id == session.id
      assert Presence.connected_count(session.id) == 0

      assert {:ok, [listed]} = Games.list_participants_with_presence(session, viewer(session))
      assert listed.id == participant.id
      refute listed.connected
    end
  end

  describe "ausência do host" do
    setup :waiting_session

    test "um refresh dentro da carência não marca ausência", %{session: session} do
      connection = connect_host(session)

      stop_connection(connection)
      connect_host(session)

      refute_receive {:host_disconnected, _expires_at}, @grace * 3
      assert is_nil(reload(session).expires_at)
    end

    test "a ausência além da carência agenda o prazo e avisa", %{session: session} do
      connection = connect_host(session)

      stop_connection(connection)

      assert_receive {:host_disconnected, expires_at}, @grace * 10

      away = reload(session)
      assert away.expires_at == expires_at
      assert away.status == :waiting
      refute is_nil(away.host_disconnected_at)

      assert DateTime.diff(expires_at, away.host_disconnected_at, :second) ==
               Games.host_absence_timeout()
    end

    test "o retorno do host cancela o prazo e avisa", %{session: session} do
      connection = connect_host(session)

      stop_connection(connection)
      assert_receive {:host_disconnected, _expires_at}, @grace * 10

      connect_host(session)

      assert_receive {:host_connected, nil}, @grace * 10

      back = reload(session)
      assert is_nil(back.expires_at)
      assert is_nil(back.host_disconnected_at)
    end

    test "uma aba a menos com o host ainda conectado não conta como ausência", %{
      session: session
    } do
      connection = connect_host(session)
      connect_host(session)

      stop_connection(connection)

      refute_receive {:host_disconnected, _expires_at}, @grace * 3
      assert Presence.host_connected?(session.id)
      assert is_nil(reload(session).expires_at)
    end

    test "um prazo herdado do banco cai quando o host reconecta", %{session: session} do
      # É a sala como o sweeper a encontra depois de um reinício: o prazo veio
      # do banco e o monitor não tem memória nenhuma dele.
      assert {:ok, _away} = Games.mark_host_disconnected(session, now())

      connect_host(session)

      assert_receive {:host_connected, nil}, @grace * 10
      assert is_nil(reload(session).expires_at)
    end
  end

  describe "carência" do
    test "vale dez segundos quando nada é configurado" do
      assert HostMonitor.default_grace_period() == :timer.seconds(10)
    end

    test "sai da configuração da aplicação" do
      assert HostMonitor.grace_period() ==
               Application.get_env(:live_quiz, HostMonitor)[:grace_period]
    end
  end

  describe "chaves e tópicos de fora" do
    setup :waiting_session

    test "um tópico que não é de sala não vira evento", %{session: session} do
      {:ok, _ref} = Presence.track(open_connection(), "outra_coisa:1", "participant:1", %{})

      refute_receive {:presence_changed, _session_id}, 200
      assert Presence.connected_count(session.id) == 0
    end

    test "uma chave que não é de participação não é contada", %{session: session} do
      topic = Games.topic(session.id)
      {:ok, _ref} = Presence.track(open_connection(), topic, "participant:sem-id", %{})

      await_presence(session.id)

      assert Presence.connected_count(session.id) == 0
      assert Presence.connected_participant_ids(session.id) == MapSet.new()
    end
  end

  describe "tolerância a falha do monitor" do
    test "uma sala que explode ao registrar a ausência não derruba o monitor" do
      {:ok, monitor} = HostMonitor.start_link(name: nil, grace_period: @grace)

      log =
        capture_log(fn ->
          send(monitor, {:confirm_absence, "sala inexistente"})
          _state = :sys.get_state(monitor)
        end)

      assert log =~ "host presence change for room sala inexistente failed"
      assert Process.alive?(monitor)

      GenServer.stop(monitor)
    end
  end

  describe "recuperação após reinício" do
    setup :waiting_session

    test "a presença volta vazia e o banco continua intacto", %{session: session} do
      participants = for _index <- 1..3, do: participant_fixture(session)
      Enum.each(participants, &connect/1)

      assert Presence.connected_count(session.id) == 3

      restart_presence()

      assert Presence.connected_count(session.id) == 0
      assert Repo.aggregate(participants_of(session), :count) == 3
      assert reload(session).status == :waiting

      assert {:ok, listed} = Games.list_participants_with_presence(session, viewer(session))
      assert length(listed) == 3
      refute Enum.any?(listed, & &1.connected)
    end

    test "quem reconecta volta a aparecer como conectado", %{session: session} do
      participant = participant_fixture(session)
      connect(participant)

      restart_presence()
      connect(participant)

      assert Presence.connected_count(session.id) == 1

      assert {:ok, [listed]} = Games.list_participants_with_presence(session, viewer(session))
      assert listed.connected
    end
  end

  describe "integração da sala cheia" do
    setup :hosted_waiting_session

    test "host e 25 participantes conectados recebem o início", %{
      scope: scope,
      session: session
    } do
      participants =
        for _index <- 1..25 do
          participant = participant_fixture(session)
          connect(participant)
          participant
        end

      subscribers = for _index <- 1..26, do: subscriber(session.id)

      assert Presence.connected_count(session.id) == 25

      assert {:ok, started} =
               Games.start_game_session(scope, session, Presence.connected_count(session.id))

      for pid <- subscribers do
        assert_receive {:event, ^pid, {:game_started, %{id: id}}}, 2_000
        assert id == started.id
      end

      assert length(participants) == 25
    end
  end

  # Every test listens to its room from the start, which is what lets the
  # helpers below wait for the presence to be fully processed instead of
  # leaving a diff in flight for the next test to trip over.
  defp waiting_session(_context) do
    host = user_fixture()
    session = game_session_fixture(%{host: host, status: :waiting})
    :ok = Games.subscribe(session.id)

    %{host: host, session: session}
  end

  defp hosted_waiting_session(_context) do
    scope = user_scope_fixture()
    session = game_session_fixture(%{host: scope.user, status: :waiting})
    :ok = Games.subscribe(session.id)

    %{scope: scope, session: session}
  end

  # The presence reports to whatever process the seam names, so each test drives
  # a monitor of its own: its grace window is short and its pending timers die
  # with it, instead of firing into the next test.
  # The monitor is stopped by hand, right after the connections of the test are
  # closed and before the sandbox owner goes away: a grace window that outlives
  # the test would wake up to query a database nobody is lending any more.
  defp own_monitor(_context) do
    {:ok, monitor} = HostMonitor.start_link(name: nil, grace_period: @grace)
    Application.put_env(:live_quiz, :host_monitor, monitor)

    on_exit(fn ->
      Application.delete_env(:live_quiz, :host_monitor)
      if Process.alive?(monitor), do: GenServer.stop(monitor)
    end)

    %{monitor: monitor}
  end

  # `track/1` is the bare registration; `connect/1` also waits for the room to
  # have been told about it, so nothing is still being processed when the test
  # ends and the sandbox takes its connection back.
  defp connect(%Participant{} = participant) do
    connection = track(participant)
    await_presence(participant.game_session_id)

    connection
  end

  defp track(%Participant{} = participant) do
    connection = open_connection()
    {:ok, _ref} = Presence.track_participant(connection, participant, Ecto.UUID.generate())

    connection
  end

  # The host arriving also reaches the monitor, so the wait goes one step
  # further: the room is only settled once the monitor has handled it.
  defp connect_host(session) do
    connection = open_connection()
    {:ok, _ref} = Presence.track_host(connection, session, Ecto.UUID.generate())
    await_presence(session.id)
    _state = :sys.get_state(HostMonitor.server())

    connection
  end

  defp await_presence(session_id) do
    assert_receive {:presence_changed, ^session_id}, 2_000
  end

  # A stand-in for the LiveView process the presence follows. It is started
  # outside the test supervisor because restarting the presence kills whatever
  # it is linked to, and a supervisor would keep bringing those back.
  defp open_connection do
    {:ok, pid} = Agent.start(fn -> :connected end)
    on_exit(fn -> stop_connection(pid) end)

    pid
  end

  defp stop_connection(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Agent.stop(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    end

    :ok
  end

  # A subscriber of its own, so the room can be shown reaching every open screen
  # at once instead of only the test process.
  defp subscriber(session_id) do
    test = self()

    pid =
      spawn_link(fn ->
        :ok = Games.subscribe(session_id)
        send(test, {:subscribed, self()})
        relay(test)
      end)

    assert_receive {:subscribed, ^pid}, 2_000

    pid
  end

  defp relay(test) do
    receive do
      message ->
        send(test, {:event, self(), message})
        relay(test)
    end
  end

  defp restart_presence do
    :ok = Supervisor.terminate_child(LiveQuiz.Supervisor, Presence)
    {:ok, _pid} = Supervisor.restart_child(LiveQuiz.Supervisor, Presence)

    :ok
  end

  defp viewer(session), do: user_scope_fixture(Repo.get!(LiveQuiz.Accounts.User, session.host_id))

  defp reload(session), do: Repo.get!(LiveQuiz.Games.GameSession, session.id)

  defp participants_of(session) do
    from p in Participant, where: p.game_session_id == ^session.id
  end
end
