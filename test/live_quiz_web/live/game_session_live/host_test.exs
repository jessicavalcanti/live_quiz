defmodule LiveQuizWeb.GameSessionLive.HostTest do
  # A presença, o monitor de ausência e o próprio LiveView vivem em processos
  # diferentes do teste, então a sandbox precisa ser compartilhada: uma corrida
  # assíncrona não emprestaria conexão a nenhum deles.
  use LiveQuizWeb.ConnCase, async: false

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import LiveQuiz.QuizzesFixtures
  import Phoenix.LiveViewTest

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.HostMonitor
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Games.Presence
  alias LiveQuiz.Repo

  # Longa de propósito: nenhum teste aqui espera a ausência do host virar
  # contagem regressiva, e uma janela curta encerraria salas no meio da suíte.
  @grace :timer.seconds(60)

  setup :own_monitor

  describe "proteção da rota" do
    test "redireciona um visitante para o login", %{conn: conn} do
      session = game_session_fixture(%{status: :waiting})

      assert {:error, {:redirect, %{to: path, flash: flash}}} =
               live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert path == ~p"/users/log-in"
      assert flash["error"] == "Você precisa entrar para acessar esta página."
    end

    test "responde 404 para a sala de outra pessoa", %{conn: conn} do
      %{conn: conn} = log_in_fresh_user(conn)
      session = game_session_fixture(%{status: :waiting})

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/game-sessions/#{session.join_code}/host")
      end
    end

    test "responde 404 para um código inexistente", %{conn: conn} do
      %{conn: conn} = log_in_fresh_user(conn)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/game-sessions/K7P4Q2/host")
      end
    end
  end

  describe "criação a partir do dashboard" do
    setup :register_and_log_in_user

    test "redireciona um visitante para o login" do
      assert build_conn()
             |> post(~p"/game-sessions", %{"quiz_id" => 1})
             |> redirected_to() == ~p"/users/log-in"
    end

    test "abre a sala e leva direto ao lobby", %{conn: conn, scope: scope} do
      quiz = quiz_fixture(scope, %{title: "Geografia"})
      question_fixture(scope, quiz)

      conn = post(conn, ~p"/game-sessions", %{"quiz_id" => quiz.id})

      session = Games.get_active_session_for_host(scope)

      assert session.quiz_id == quiz.id
      assert redirected_to(conn) == ~p"/game-sessions/#{session.join_code}/host"
    end

    test "recusa um quiz sem perguntas e explica", %{conn: conn, scope: scope} do
      quiz = quiz_fixture(scope)

      conn = post(conn, ~p"/game-sessions", %{"quiz_id" => quiz.id})

      assert redirected_to(conn) == ~p"/quizzes"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "Adicione ao menos uma pergunta"

      assert Games.get_active_session_for_host(scope) == nil
    end

    test "responde 404 para o quiz de outra pessoa", %{conn: conn} do
      foreign = quiz_fixture(user_scope_fixture())

      assert_error_sent 404, fn ->
        post(conn, ~p"/game-sessions", %{"quiz_id" => foreign.id})
      end
    end

    test "leva quem já tem sala aberta para a sala dela", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      open = game_session_fixture(%{host: user, status: :waiting})
      another = quiz_fixture(scope, %{title: "História"})
      question_fixture(scope, another)

      conn = post(conn, ~p"/game-sessions", %{"quiz_id" => another.id})

      assert redirected_to(conn) == ~p"/game-sessions/#{open.join_code}/host"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "já tem uma sala aberta"
    end

    test "recusa quem está participando de outra sala", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      other_room = game_session_fixture(%{status: :waiting})
      participant_fixture(other_room, %{user: user})

      quiz = quiz_fixture(scope, %{title: "Geografia"})
      question_fixture(scope, quiz)

      conn = post(conn, ~p"/game-sessions", %{"quiz_id" => quiz.id})

      assert redirected_to(conn) == ~p"/quizzes"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Saia da sala"
      assert Games.get_active_session_for_host(scope) == nil
    end
  end

  describe "lobby recém-aberto" do
    setup [:register_and_log_in_user, :waiting_room]

    test "mostra o código, o título e os contadores", %{conn: conn, session: session} do
      {:ok, lv, html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert html =~ "Geografia"
      assert lv |> element("#join-code") |> render() =~ session.join_code
      assert lv |> element("#reserved-count") |> render() =~ "0"
      assert lv |> element("#connected-count") |> render() =~ "0"
      assert has_element?(lv, "#participants-empty")
    end

    test "encontra a sala por um código digitado em minúsculas", %{
      conn: conn,
      session: session
    } do
      typed = String.downcase(session.join_code)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{typed}/host")

      assert lv |> element("#join-code") |> render() =~ session.join_code
    end

    test "registra a presença do host e assume o acesso da sala", %{
      conn: conn,
      session: session
    } do
      {:ok, _lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert Presence.host_connected?(session.id)
      assert Repo.get!(GameSession, session.id).host_connection_id
    end

    test "lista quem já estava na sala, com quem está conectado", %{
      conn: conn,
      session: session
    } do
      present = participant_fixture(session, %{nickname: "Ana"})
      absent = participant_fixture(session, %{nickname: "Bruno"})
      connect_participant(present)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert has_element?(lv, "#participants-#{present.id}")
      assert has_element?(lv, "#participants-#{absent.id}")
      refute has_element?(lv, "#participants-empty")

      assert lv |> element("#reserved-count") |> render() =~ "2"
      assert lv |> element("#connected-count") |> render() =~ "1"
    end

    test "não lista quem saiu da sala", %{conn: conn, session: session} do
      staying = participant_fixture(session, %{nickname: "Ana"})
      leaving = participant_fixture(session, %{nickname: "Bruno"})
      {:ok, _left} = Games.leave_game_session(leaving)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert has_element?(lv, "#participants-#{staying.id}")
      refute has_element?(lv, "#participants-#{leaving.id}")
      assert lv |> element("#reserved-count") |> render() =~ "2"
    end

    test "confirma a cópia do código", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert lv |> element("#copy-code") |> render_click() =~ "Código copiado"
    end
  end

  describe "contadores" do
    setup [:register_and_log_in_user, :waiting_room]

    test "separa inscritos de conectados e omite quem saiu", %{conn: conn, session: session} do
      participants = for index <- 1..5, do: participant_fixture(session, %{nickname: "P#{index}"})
      [first, second, third, fourth, fifth] = participants

      Enum.each([first, second, third], &connect_participant/1)
      {:ok, _left} = Games.leave_game_session(fifth)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert lv |> element("#reserved-count") |> render() =~ "Inscritos:"
      assert lv |> element("#reserved-count") |> render() =~ "5"
      assert lv |> element("#reserved-count") |> render() =~ "de 25"
      assert lv |> element("#connected-count") |> render() =~ "Conectados agora:"
      assert lv |> element("#connected-count") |> render() =~ "3"

      for participant <- [first, second, third, fourth] do
        assert has_element?(lv, "#participants-#{participant.id}")
      end

      refute has_element?(lv, "#participants-#{fifth.id}")
    end

    test "avisa que a sala está lotada", %{conn: conn, session: session} do
      for index <- 1..Games.max_participants() do
        participant_fixture(session, %{nickname: "P#{index}"})
      end

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert lv |> element("#reserved-count") |> render() =~ "25"
      assert has_element?(lv, "#room-full-notice")
    end

    test "uma sala com vagas não é anunciada como lotada", %{conn: conn, session: session} do
      participant_fixture(session)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      refute has_element?(lv, "#room-full-notice")
    end
  end

  describe "eventos da sala" do
    setup [:register_and_log_in_user, :waiting_room]

    test "a entrada de alguém aparece sem recarregar a página", %{
      conn: conn,
      session: session
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert has_element?(lv, "#participants-empty")

      participant = participant_fixture(session, %{nickname: "Ana"})
      send(lv.pid, {:participant_joined, participant})

      assert has_element?(lv, "#participants-#{participant.id}")
      assert lv |> element("#participants-#{participant.id}") |> render() =~ "Ana"
      assert lv |> element("#reserved-count") |> render() =~ "1"
      refute has_element?(lv, "#participants-empty")
    end

    test "a saída remove da lista sem devolver a vaga", %{conn: conn, session: session} do
      participant = participant_fixture(session, %{nickname: "Ana"})

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")
      assert has_element?(lv, "#participants-#{participant.id}")

      {:ok, left} = Games.leave_game_session(participant)
      send(lv.pid, {:participant_left, left})

      refute has_element?(lv, "#participants-#{participant.id}")
      assert lv |> element("#reserved-count") |> render() =~ "1"
    end

    test "o retorno traz a pessoa de volta para a lista", %{conn: conn, session: session} do
      participant = participant_fixture(session, %{nickname: "Ana"})
      {:ok, left} = Games.leave_game_session(participant)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")
      refute has_element?(lv, "#participants-#{participant.id}")

      back =
        Repo.update!(Participant.connection_changeset(left, %{left_at: nil, released_at: nil}))

      send(lv.pid, {:participant_rejoined, back})

      assert has_element?(lv, "#participants-#{participant.id}")
    end

    test "a queda de conexão mantém a pessoa na lista, marcada", %{
      conn: conn,
      session: session
    } do
      participant = participant_fixture(session, %{nickname: "Ana"})
      connection = connect_participant(participant)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert lv |> element("#connected-count") |> render() =~ "1"
      refute lv |> element("#participants-#{participant.id}") |> render() =~ "desconectado"

      stop_connection(connection)
      send(lv.pid, {:presence_changed, session.id})

      assert has_element?(lv, "#participants-#{participant.id}")
      assert lv |> element("#participants-#{participant.id}") |> render() =~ "desconectado"
      assert lv |> element("#connected-count") |> render() =~ "0"
      assert lv |> element("#reserved-count") |> render() =~ "1"
    end

    test "a transferência de acesso de um participante não muda a lista", %{
      conn: conn,
      session: session
    } do
      participant = participant_fixture(session, %{nickname: "Ana"})

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      send(lv.pid, {:access_transferred, participant.id, Ecto.UUID.generate()})

      assert has_element?(lv, "#participants-#{participant.id}")
    end
  end

  describe "iniciar a partida" do
    setup [:register_and_log_in_user, :waiting_room]

    test "o botão fica desabilitado sem ninguém conectado e o motivo é exibido", %{
      conn: conn,
      session: session
    } do
      participant_fixture(session)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert has_element?(lv, "#start-game[disabled]")
      assert has_element?(lv, ~s{#start-game[aria-disabled="true"]})
      assert has_element?(lv, ~s{#start-game[aria-describedby="start-hint"]})
      assert lv |> element("#start-hint") |> render() =~ "Ninguém está conectado ainda"
    end

    test "o botão habilita com uma pessoa conectada", %{conn: conn, session: session} do
      session |> participant_fixture() |> connect_participant()

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      refute has_element?(lv, "#start-game[disabled]")
      assert has_element?(lv, ~s{#start-game[aria-disabled="false"]})
      refute has_element?(lv, "#start-hint")
    end

    test "iniciar troca a tela para partida iniciada", %{conn: conn, session: session} do
      session |> participant_fixture() |> connect_participant()

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      html = lv |> element("#start-game") |> render_click()

      assert html =~ "Partida iniciada"
      assert has_element?(lv, "#game-started")
      refute has_element?(lv, "#join-code-panel")
      refute has_element?(lv, "#start-game")

      assert Repo.get!(GameSession, session.id).status == :in_progress
    end

    test "um clique forçado sem ninguém conectado não inicia a sala", %{
      conn: conn,
      session: session
    } do
      participant_fixture(session)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      html = render_click(lv, "start", %{})

      assert html =~ "A partida só começa com pelo menos uma pessoa conectada"
      assert Repo.get!(GameSession, session.id).status == :waiting
      assert has_element?(lv, "#join-code-panel")
    end

    test "o evento de início chegado de outra aba atualiza a tela", %{
      conn: conn,
      session: session
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      send(lv.pid, {:game_started, %{session | status: :in_progress}})

      assert has_element?(lv, "#game-started")
    end
  end

  describe "cancelar a sala" do
    setup [:register_and_log_in_user, :waiting_room]

    test "o clique pede confirmação e mantém a sala aberta", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      lv |> element("#cancel-room") |> render_click()

      assert has_element?(lv, "#cancel-room-modal")
      assert Repo.get!(GameSession, session.id).status == :waiting
    end

    test "fechar o modal não cancela nada", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      lv |> element("#cancel-room") |> render_click()
      lv |> element("#cancel-room-modal button", "Manter a sala") |> render_click()

      refute has_element?(lv, "#cancel-room-modal")
      assert Repo.get!(GameSession, session.id).status == :waiting
    end

    test "confirmar encerra a sala e oferece a volta ao dashboard", %{
      conn: conn,
      session: session
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      lv |> element("#cancel-room") |> render_click()
      html = lv |> element("#confirm-cancel") |> render_click()

      assert html =~ "Sala cancelada"
      assert has_element?(lv, "#room-closed")
      assert has_element?(lv, ~s{#back-to-quizzes[href="/quizzes"]})
      refute has_element?(lv, "#start-game")
      refute has_element?(lv, "#cancel-room")

      assert Repo.get!(GameSession, session.id).status == :cancelled
    end

    test "o cancelamento vindo de outra aba atualiza a tela", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      {:ok, _cancelled} = Games.cancel_game_session(Scope.for_user(host(session)), session)

      assert has_element?(lv, "#room-closed")
      assert render(lv) =~ "Sala cancelada"
    end

    test "cancelar uma sala já encerrada por trás da tela avisa sem quebrar", %{
      conn: conn,
      session: session
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      # A sala é encerrada sem passar pelo contexto, então nenhum evento chega
      # ao LiveView: é a corrida entre o clique do host e o prazo de expiração.
      Repo.update!(GameSession.status_changeset(session, :expired))

      lv |> element("#cancel-room") |> render_click()
      html = lv |> element("#confirm-cancel") |> render_click()

      assert html =~ "Esta sala não está mais no estado necessário"
    end

    test "a expiração aparece com o motivo da ausência", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      {:ok, _expired} = Games.expire_game_session(session)

      assert has_element?(lv, "#room-closed")
      assert render(lv) =~ "Sala encerrada por ausência"
      refute has_element?(lv, "#start-game")
      refute has_element?(lv, "#cancel-room")
    end
  end

  describe "sala já encerrada" do
    setup :register_and_log_in_user

    test "o host que volta lê que a sala expirou e não comanda mais nada", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      quiz = quiz_fixture(scope, %{title: "Geografia"})
      session = game_session_fixture(%{host: user, quiz: quiz, status: :expired})

      {:ok, lv, html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert html =~ "Sala encerrada por ausência"
      assert has_element?(lv, "#room-closed")
      refute has_element?(lv, "#start-game")
      refute has_element?(lv, "#cancel-room")
      refute has_element?(lv, "#join-code-panel")
    end

    test "uma partida já finalizada mostra o fim", %{conn: conn, user: user, scope: scope} do
      quiz = quiz_fixture(scope, %{title: "Geografia"})
      session = game_session_fixture(%{host: user, quiz: quiz, status: :finished})

      {:ok, lv, html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert html =~ "Partida encerrada"
      assert has_element?(lv, "#room-closed")
    end

    test "uma sala encerrada não registra presença nem toma o acesso", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      quiz = quiz_fixture(scope, %{title: "Geografia"})
      session = game_session_fixture(%{host: user, quiz: quiz, status: :cancelled})

      {:ok, _lv, html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert html =~ "Sala cancelada"
      refute Presence.host_connected?(session.id)
      refute Repo.get!(GameSession, session.id).host_connection_id
    end
  end

  describe "transferência de acesso do host" do
    setup [:register_and_log_in_user, :waiting_room]

    test "a segunda aba assume o controle e a primeira para de comandar", %{
      conn: conn,
      session: session
    } do
      {:ok, first, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")
      {:ok, _second, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert has_element?(first, "#access-lost-notice")
      assert render(first) =~ "O controle desta sala foi assumido em outro dispositivo"
      assert has_element?(first, "#start-game[disabled]")
      assert has_element?(first, "#cancel-room[disabled]")
    end

    test "o próprio id de conexão não tira o controle da tela", %{
      conn: conn,
      session: session
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      connection_id = Repo.get!(GameSession, session.id).host_connection_id
      send(lv.pid, {:host_access_transferred, connection_id})

      refute has_element?(lv, "#access-lost-notice")
      refute has_element?(lv, "#cancel-room[disabled]")
    end

    test "a tela sem acesso recusa iniciar e cancelar", %{conn: conn, session: session} do
      session |> participant_fixture() |> connect_participant()

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      send(lv.pid, {:host_access_transferred, Ecto.UUID.generate()})

      render_click(lv, "start", %{})
      render_click(lv, "confirm_cancel", %{})

      assert Repo.get!(GameSession, session.id).status == :waiting
    end
  end

  describe "aviso de expiração por ausência" do
    setup [:register_and_log_in_user, :waiting_room]

    test "o host que reconecta vê o prazo pendente", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      expires_at = DateTime.add(DateTime.utc_now(), 300, :second)
      send(lv.pid, {:host_disconnected, DateTime.truncate(expires_at, :second)})

      assert has_element?(lv, "#expiration-notice")
      assert render(lv) =~ "encerrada por ausência"
    end

    test "o retorno do host derruba o aviso", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      send(lv.pid, {:host_disconnected, DateTime.truncate(DateTime.utc_now(), :second)})
      assert has_element?(lv, "#expiration-notice")

      send(lv.pid, {:host_connected, nil})
      refute has_element?(lv, "#expiration-notice")
    end
  end

  describe "acessibilidade" do
    setup [:register_and_log_in_user, :waiting_room]

    test "o estado desconectado é comunicado por texto, não só por cor", %{
      conn: conn,
      session: session
    } do
      participant = participant_fixture(session, %{nickname: "Ana"})

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      rendered = lv |> element("#participants-#{participant.id}") |> render()

      assert rendered =~ "desconectado"
      assert rendered =~ ~s(aria-hidden="true")
    end

    test "o botão desabilitado aponta para o motivo", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert has_element?(lv, ~s{#start-game[aria-describedby="start-hint"]})
      assert has_element?(lv, "#start-hint")
    end
  end

  defp waiting_room(%{user: user, scope: scope}) do
    quiz = quiz_fixture(scope, %{title: "Geografia"})
    question_fixture(scope, quiz)
    session = game_session_fixture(%{host: user, quiz: quiz, status: :waiting})

    :ok = Games.subscribe(session.id)

    %{quiz: quiz, session: session}
  end

  defp log_in_fresh_user(conn) do
    user = user_fixture()

    %{conn: log_in_user(conn, user), user: user, scope: Scope.for_user(user)}
  end

  defp host(%GameSession{host_id: host_id}), do: Repo.get!(LiveQuiz.Accounts.User, host_id)

  # Um monitor próprio, parado ao fim do teste: parar o processo espera o
  # `cast` que a presença do host acabou de mandar terminar, então nenhuma
  # leitura sobra de um teste para o outro.
  defp own_monitor(_context) do
    {:ok, monitor} = HostMonitor.start_link(name: nil, grace_period: @grace)
    Application.put_env(:live_quiz, :host_monitor, monitor)

    on_exit(fn ->
      Application.delete_env(:live_quiz, :host_monitor)
      if Process.alive?(monitor), do: GenServer.stop(monitor)
    end)

    %{monitor: monitor}
  end

  # O teste assina o tópico da sala no `waiting_room`, então esperar o aviso de
  # presença garante que o rastreamento já foi processado antes da asserção.
  defp connect_participant(%Participant{} = participant) do
    {:ok, connection} = Agent.start(fn -> :connected end)
    # O `on_exit` roda em outro processo, sem a caixa de mensagens do teste:
    # aqui só se garante que a conexão não sobrevive ao teste.
    on_exit(fn -> Process.exit(connection, :kill) end)

    {:ok, _ref} = Presence.track_participant(connection, participant, Ecto.UUID.generate())
    assert_receive {:presence_changed, _session_id}, 2_000

    connection
  end

  defp stop_connection(connection) do
    ref = Process.monitor(connection)
    Agent.stop(connection)

    assert_receive {:DOWN, ^ref, :process, ^connection, _reason}, 2_000
    assert_receive {:presence_changed, _session_id}, 2_000

    :ok
  end
end
