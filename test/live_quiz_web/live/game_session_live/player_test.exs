defmodule LiveQuizWeb.GameSessionLive.PlayerTest do
  # A presença e a própria LiveView vivem em processos diferentes do teste,
  # então a sandbox precisa ser compartilhada: uma corrida assíncrona não
  # emprestaria conexão a nenhum deles.
  use LiveQuizWeb.ConnCase, async: false

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import Phoenix.LiveViewTest

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Accounts.User
  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Games.Presence
  alias LiveQuiz.Repo
  alias LiveQuizWeb.ParticipantAuth

  @cookie ParticipantAuth.cookie_name()

  describe "entrada na tela" do
    setup :room_with_ana

    test "mostra o título do quiz, o próprio apelido e a lista", %{
      conn: conn,
      session: session,
      participant: participant
    } do
      {:ok, lv, html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      assert html =~ "Geografia"
      assert lv |> element("#own-nickname") |> render() =~ "Você entrou como"
      assert lv |> element("#own-nickname") |> render() =~ "Ana"
      assert has_element?(lv, "#participants-#{participant.id}")
      assert lv |> element("#waiting-notice") |> render() =~ "Aguardando o host iniciar a partida"
    end

    test "encontra a sala por um código digitado em minúsculas", %{
      conn: conn,
      session: session
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{String.downcase(session.join_code)}")

      assert has_element?(lv, "#own-nickname")
    end

    test "a renderização estática avisa que está entrando, em vez de ficar em branco", %{
      conn: conn,
      session: session
    } do
      conn = get(conn, ~p"/game-sessions/#{session.join_code}")

      assert html_response(conn, 200) =~ "Entrando na sala"
    end

    test "registra a presença e assume o acesso da participação", %{
      conn: conn,
      session: session,
      participant: participant
    } do
      {:ok, _lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      assert Presence.connected_participant_ids(session.id) == MapSet.new([participant.id])
      assert Repo.get!(Participant, participant.id).connection_id != nil
    end

    test "lista quem já estava na sala, marcando quem está desconectado", %{
      conn: conn,
      session: session
    } do
      other = participant_fixture(session, %{nickname: "Bruno"})

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      assert lv |> element("#participants-#{other.id}") |> render() =~ "Bruno"
      assert lv |> element("#participants-#{other.id}") |> render() =~ "desconectado"
    end

    test "não lista quem saiu da sala", %{conn: conn, session: session} do
      gone = participant_fixture(session, %{nickname: "Bruno"})
      {:ok, _left} = Games.leave_game_session(gone)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      refute has_element?(lv, "#participants-#{gone.id}")
    end
  end

  describe "credencial ausente ou de outra sala" do
    test "sem credencial, leva para a tela de entrada com o código", %{conn: conn} do
      session = game_session_fixture(%{status: :waiting})

      assert {:error, {:redirect, %{to: path}}} =
               live(conn, ~p"/game-sessions/#{session.join_code}")

      assert path == ~p"/join?code=#{session.join_code}"
    end

    test "com a credencial de outra sala, leva para a tela de entrada", %{conn: conn} do
      session = game_session_fixture(%{status: :waiting})
      other = game_session_fixture(%{status: :waiting})
      {:ok, _participant, token} = join(other, "Ana")

      conn = put_participant_token(conn, session.join_code, token)

      assert {:error, {:redirect, %{to: path}}} =
               live(conn, ~p"/game-sessions/#{session.join_code}")

      assert path == ~p"/join?code=#{session.join_code}"
    end

    test "com uma credencial que não vale nada, leva para a tela de entrada", %{conn: conn} do
      session = game_session_fixture(%{status: :waiting})
      conn = put_participant_token(conn, session.join_code, "credencial-que-nao-vale-nada")

      assert {:error, {:redirect, %{to: path}}} =
               live(conn, ~p"/game-sessions/#{session.join_code}")

      assert path == ~p"/join?code=#{session.join_code}"
    end
  end

  describe "retorno automático" do
    setup :room_with_ana

    test "recarregar a página não cria uma segunda participação", %{
      conn: conn,
      session: session,
      participant: participant
    } do
      assert Games.reserved_slots(session) == 1

      {:ok, _lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      assert Games.reserved_slots(session) == 1
      assert has_element?(lv, "#participants-#{participant.id}")
      assert Repo.get!(Participant, participant.id).nickname == "Ana"
    end

    test "voltar depois de sair recupera a mesma participação", %{
      conn: conn,
      session: session,
      participant: participant
    } do
      {:ok, _left} = Games.leave_game_session(participant)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      assert lv |> element("#own-nickname") |> render() =~ "Ana"
      assert has_element?(lv, "#participants-#{participant.id}")
      assert Games.reserved_slots(session) == 1

      back = Repo.get!(Participant, participant.id)
      assert back.left_at == nil
      assert back.released_at == nil
    end

    test "quem voltou reaparece na lista dos demais", %{
      conn: conn,
      session: session,
      participant: participant
    } do
      watcher = watcher_view(session)
      {:ok, _left} = Games.leave_game_session(participant)

      refute has_element?(watcher, "#participants-#{participant.id}")

      {:ok, _lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      assert_receive {:participant_rejoined, _participant}, 2_000
      send(watcher.pid, {:participant_rejoined, participant})

      assert has_element?(watcher, "#participants-#{participant.id}")
    end

    test "voltar depois do início mostra a partida iniciada", %{
      conn: conn,
      session: session
    } do
      start_room(session)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      assert has_element?(lv, "#game-started")
      assert lv |> element("#game-started") |> render() =~ "Partida iniciada"
      refute has_element?(lv, "#waiting-notice")
    end
  end

  describe "sala já encerrada" do
    setup :room_with_ana

    test "a sala cancelada explica o cancelamento e oferece a saída", %{
      conn: conn,
      session: session
    } do
      close_room(session, :cancelled)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      assert lv |> element("#room-closed") |> render() =~ "cancelada"
      assert has_element?(lv, "#back-to-join")
      refute has_element?(lv, "#leave-form")
    end

    test "a sala expirada explica a ausência do host", %{conn: conn, session: session} do
      close_room(session, :expired)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      assert lv |> element("#room-closed") |> render() =~ "ausência do host"
      assert has_element?(lv, "#back-to-join")
    end

    test "uma partida já finalizada mostra o fim, sem culpar ninguém", %{
      conn: conn,
      session: session
    } do
      close_room(session, :finished)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      rendered = lv |> element("#room-closed") |> render()

      assert rendered =~ "Partida encerrada"
      refute rendered =~ "cancelada"
      refute rendered =~ "ausência"
    end

    test "a sala encerrada não registra presença", %{conn: conn, session: session} do
      close_room(session, :cancelled)

      {:ok, _lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      assert Presence.connected_participant_ids(session.id) == MapSet.new()
    end
  end

  describe "preso em outra sala" do
    test "avisa e aponta para a sala que está segurando a pessoa", %{conn: conn} do
      reserved = game_session_fixture(%{status: :waiting, quiz_title: "Geografia"})
      other = game_session_fixture(%{status: :waiting, quiz_title: "História"})

      {:ok, participant, reserved_token} = join(reserved, "Ana")
      {:ok, _left} = Games.leave_game_session(participant)
      {:ok, _elsewhere, other_token} = join(other, "Ana", known_tokens: [reserved_token])

      conn =
        conn
        |> put_participant_token(reserved.join_code, reserved_token)
        |> put_participant_token(other.join_code, other_token)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{reserved.join_code}")

      assert lv |> element("#another-room-notice") |> render() =~ "outra sala"
      assert has_element?(lv, "#back-to-other-room")

      # A participação reservada segue exatamente como estava: o aviso não
      # mexeu em nada no banco.
      still_out = Repo.get!(Participant, participant.id)
      assert still_out.released_at != nil
      assert Presence.connected_participant_ids(reserved.id) == MapSet.new()
    end

    test "sem credencial da outra sala, o aviso ainda leva para a entrada", %{conn: conn} do
      user = user_fixture()
      reserved = game_session_fixture(%{status: :waiting})
      other = game_session_fixture(%{status: :waiting})

      {:ok, participant, token} = join(reserved, "Ana", user: user)
      {:ok, _left} = Games.leave_game_session(participant)
      {:ok, _elsewhere, _other_token} = join(other, "Ana", user: user)

      conn = put_participant_token(conn, reserved.join_code, token)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{reserved.join_code}")

      assert has_element?(lv, "#another-room-notice")
      assert has_element?(lv, "#back-to-join")
      refute has_element?(lv, "#back-to-other-room")
    end
  end

  describe "eventos da sala" do
    setup :room_with_ana

    test "a entrada de outra pessoa aparece sem recarregar", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      bruno = participant_fixture(session, %{nickname: "Bruno"})
      send(lv.pid, {:participant_joined, bruno})

      assert has_element?(lv, "#participants-#{bruno.id}")
      assert lv |> element("#participants-#{bruno.id}") |> render() =~ "Bruno"
    end

    test "a saída de outra pessoa some da lista", %{conn: conn, session: session} do
      bruno = participant_fixture(session, %{nickname: "Bruno"})

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")
      assert has_element?(lv, "#participants-#{bruno.id}")

      {:ok, left} = Games.leave_game_session(bruno)
      send(lv.pid, {:participant_left, left})

      refute has_element?(lv, "#participants-#{bruno.id}")
    end

    test "a queda de conexão de outra pessoa a mantém na lista, marcada", %{
      conn: conn,
      session: session
    } do
      bruno = participant_fixture(session, %{nickname: "Bruno"})
      connection = connect_participant(bruno)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")
      refute lv |> element("#participants-#{bruno.id}") |> render() =~ "desconectado"

      stop_connection(connection)
      send(lv.pid, {:presence_changed, session.id})

      assert has_element?(lv, "#participants-#{bruno.id}")
      assert lv |> element("#participants-#{bruno.id}") |> render() =~ "desconectado"
    end

    test "a partida iniciada troca a tela", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      assert has_element?(lv, "#waiting-notice")

      send(lv.pid, {:game_started, %{session | status: :in_progress}})

      assert lv |> element("#game-started") |> render() =~ "Partida iniciada"
      refute has_element?(lv, "#waiting-notice")
    end

    test "o cancelamento leva à tela de sala cancelada", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      send(lv.pid, {:game_cancelled, %{session | status: :cancelled}})

      rendered = lv |> element("#room-closed") |> render()

      assert rendered =~ "cancelada"
      refute rendered =~ "ausência"
      assert has_element?(lv, "#back-to-join")
    end

    test "a expiração leva a uma tela distinta, com o motivo da ausência", %{
      conn: conn,
      session: session
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      send(lv.pid, {:game_expired, %{session | status: :expired}})

      rendered = lv |> element("#room-closed") |> render()

      assert rendered =~ "ausência do host"
      refute rendered =~ "cancelada"
      assert has_element?(lv, "#back-to-join")
    end

    test "a sala encerrada não mostra mais o botão de sair", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      send(lv.pid, {:game_cancelled, %{session | status: :cancelled}})

      refute has_element?(lv, "#leave-form")
    end

    test "a tela final ignora os eventos que continuam chegando", %{
      conn: conn,
      session: session
    } do
      bruno = participant_fixture(session, %{nickname: "Bruno"})

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")
      send(lv.pid, {:game_cancelled, %{session | status: :cancelled}})

      send(lv.pid, {:participant_joined, bruno})
      send(lv.pid, {:presence_changed, session.id})

      assert has_element?(lv, "#room-closed")
      refute has_element?(lv, "#participants-#{bruno.id}")
    end

    test "a sala encerrada recusa o evento de sair forçado à mão", %{
      conn: conn,
      session: session,
      participant: participant
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")
      send(lv.pid, {:game_cancelled, %{session | status: :cancelled}})

      render_click(lv, "leave", %{})

      assert Repo.get!(Participant, participant.id).left_at == nil
      assert has_element?(lv, "#room-closed")
    end
  end

  describe "aviso de host desconectado" do
    setup :room_with_ana

    test "o host desconectado aparece sem contagem regressiva", %{
      conn: conn,
      session: session
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      refute has_element?(lv, "#host-away-notice")

      send(lv.pid, {:host_disconnected, DateTime.add(DateTime.utc_now(), 300)})

      notice = lv |> element("#host-away-notice") |> render()

      assert notice =~ "O host está desconectado"
      refute notice =~ "encerrada em"
      refute notice =~ "segundos"
      refute notice =~ "minutos"
      refute has_element?(lv, "#expiration-notice")
    end

    test "o retorno do host derruba o aviso", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      send(lv.pid, {:host_disconnected, DateTime.add(DateTime.utc_now(), 300)})
      assert has_element?(lv, "#host-away-notice")

      send(lv.pid, {:host_connected, nil})

      refute has_element?(lv, "#host-away-notice")
    end

    test "quem entra numa sala já sem host lê o aviso", %{conn: conn, session: session} do
      {:ok, _session} = Games.mark_host_disconnected(session)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      assert has_element?(lv, "#host-away-notice")
    end
  end

  describe "transferência de acesso" do
    setup :room_with_ana

    test "a segunda aba assume e a primeira informa a perda", %{
      conn: conn,
      session: session,
      participant: participant
    } do
      :ok = Games.subscribe(session.id)

      {:ok, first, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")
      assert_receive {:access_transferred, _id, first_connection}, 2_000

      {:ok, _second, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")
      assert_receive {:access_transferred, _id, second_connection}, 2_000

      refute first_connection == second_connection

      assert first |> element("#access-lost-notice") |> render() =~ "outro lugar"
      refute has_element?(first, "#leave-form")

      # Continua existindo uma única participação.
      assert Games.reserved_slots(session) == 1
      assert Repo.get!(Participant, participant.id).connection_id == second_connection
    end

    test "o próprio id de conexão não tira a tela do ar", %{
      conn: conn,
      session: session,
      participant: participant
    } do
      :ok = Games.subscribe(session.id)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")
      assert_receive {:access_transferred, _id, connection_id}, 2_000

      send(lv.pid, {:access_transferred, participant.id, connection_id})

      refute has_element?(lv, "#access-lost-notice")
      assert has_element?(lv, "#own-nickname")
    end

    test "a tela sem acesso recusa o evento de sair forçado à mão", %{
      conn: conn,
      session: session,
      participant: participant
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      send(lv.pid, {:access_transferred, participant.id, Ecto.UUID.generate()})
      assert has_element?(lv, "#access-lost-notice")

      render_click(lv, "leave", %{})

      assert Repo.get!(Participant, participant.id).left_at == nil
    end

    test "a transferência de outra participação não muda esta tela", %{
      conn: conn,
      session: session
    } do
      bruno = participant_fixture(session, %{nickname: "Bruno"})

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      send(lv.pid, {:access_transferred, bruno.id, Ecto.UUID.generate()})

      refute has_element?(lv, "#access-lost-notice")
      assert has_element?(lv, "#participants-#{bruno.id}")
    end

    test "o host assumindo a própria sala não muda esta tela", %{
      conn: conn,
      session: session
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      send(lv.pid, {:host_access_transferred, Ecto.UUID.generate()})

      assert has_element?(lv, "#own-nickname")
      refute has_element?(lv, "#access-lost-notice")
    end
  end

  describe "sair da sala" do
    setup :room_with_ana

    test "sai do lobby, limpa a credencial da sala e libera outra entrada", %{
      conn: conn,
      session: session,
      participant: participant
    } do
      other = game_session_fixture(%{status: :waiting})

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      form = form(lv, "#leave-form")
      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/join"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "saiu da sala"
      assert remaining_tokens(conn) == %{}

      # A participação foi encerrada, então a pessoa pode entrar em outra sala.
      assert Repo.get!(Participant, participant.id).released_at != nil
      assert {:ok, _participant, _token} = join(other, "Ana")
    end

    test "os demais deixam de ver quem saiu", %{conn: conn, session: session} do
      watcher = watcher_view(session)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      render_submit(form(lv, "#leave-form"))

      assert_receive {:participant_left, left}, 2_000
      send(watcher.pid, {:participant_left, left})

      refute has_element?(watcher, "#participants-#{left.id}")
    end

    test "sair não devolve a vaga: a sala continua lotada", %{
      conn: conn,
      session: session,
      participant: participant
    } do
      for _seat <- 2..Games.max_participants(), do: participant_fixture(session)
      assert Games.reserved_slots(session) == Games.max_participants()

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")
      render_submit(form(lv, "#leave-form"))

      assert Repo.get!(Participant, participant.id).released_at != nil
      assert {:error, :session_full} = join(session, "Bruno")
    end

    test "a credencial das outras salas continua no navegador", %{
      conn: conn,
      session: session
    } do
      other = game_session_fixture(%{status: :waiting})
      conn = put_participant_token(conn, other.join_code, "token-de-outra-sala")

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      form = form(lv, "#leave-form")
      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert remaining_tokens(conn) == %{other.join_code => "token-de-outra-sala"}
    end
  end

  describe "apelido fixo" do
    setup :room_with_ana

    test "não existe nenhum controle de alteração de apelido", %{
      conn: conn,
      session: session
    } do
      {:ok, lv, html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      refute has_element?(lv, "input[name*='nickname']")
      refute has_element?(lv, "#nickname-form")
      refute html =~ "Trocar apelido"
      refute html =~ "Alterar apelido"
    end
  end

  describe "acessibilidade" do
    setup :room_with_ana

    test "o estado desconectado é comunicado por texto, não só por cor", %{
      conn: conn,
      session: session
    } do
      bruno = participant_fixture(session, %{nickname: "Bruno"})

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      rendered = lv |> element("#participants-#{bruno.id}") |> render()

      assert rendered =~ "desconectado"
      assert rendered =~ ~s(aria-hidden="true")
    end

    test "os avisos ficam em uma região aria-live", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      assert has_element?(lv, ~s{#notices[aria-live="polite"]})

      send(lv.pid, {:host_disconnected, DateTime.add(DateTime.utc_now(), 300)})

      assert lv |> element(~s{#notices[aria-live="polite"]}) |> render() =~
               "O host está desconectado"
    end

    test "o próprio apelido é identificado como (você) em texto", %{
      conn: conn,
      session: session,
      participant: participant
    } do
      other = participant_fixture(session, %{nickname: "Bruno"})

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      assert lv |> element("#participants-#{participant.id}") |> render() =~ "(você)"
      refute lv |> element("#participants-#{other.id}") |> render() =~ "(você)"
    end

    test "a lista de participantes é rotulada pelo próprio título", %{
      conn: conn,
      session: session
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      assert has_element?(lv, ~s{#participants[aria-labelledby="participants-title"]})
      assert has_element?(lv, "#participants-title")
    end
  end

  # Uma sala esperando, com "Ana" já dentro e a credencial dela no navegador —
  # o estado em que a tela é aberta na esmagadora maioria das vezes.
  defp room_with_ana(%{conn: conn}) do
    session = game_session_fixture(%{status: :waiting, quiz_title: "Geografia"})
    {:ok, participant, token} = join(session, "Ana")

    %{
      conn: put_participant_token(conn, session.join_code, token),
      session: session,
      participant: participant,
      token: token
    }
  end

  defp join(session, nickname, opts \\ []) do
    {user, opts} = Keyword.pop(opts, :user)
    scope = user && Scope.for_user(user)

    Games.join_game_session(scope, session.join_code, %{"nickname" => nickname}, opts)
  end

  # Outra pessoa já no lobby, com a própria LiveView, para observar o que os
  # demais deixam de ver. O teste assina o tópico junto, porque é por ele que
  # sabe que o evento já foi publicado antes de repassá-lo.
  defp watcher_view(session) do
    {:ok, _watcher, token} = join(session, "Bruno")

    conn =
      build_conn()
      |> put_participant_token(session.join_code, token)

    :ok = Games.subscribe(session.id)
    {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

    lv
  end

  defp start_room(session) do
    host = Repo.get!(User, session.host_id)
    scope = Scope.for_user(host)

    {:ok, session} = Games.start_game_session(scope, session, 1)

    session
  end

  defp close_room(session, :cancelled) do
    host = Repo.get!(User, session.host_id)
    scope = Scope.for_user(host)

    {:ok, session} = Games.cancel_game_session(scope, session)

    session
  end

  defp close_room(session, :expired) do
    {:ok, session} = Games.expire_game_session(session)

    session
  end

  # A fase 2 não tem como terminar uma partida: o fim vem na fase 3. A sala é
  # levada ao estado final pelo schema, que é o que a tela vai encontrar lá.
  defp close_room(session, :finished) do
    session |> GameSession.status_changeset(:finished) |> Repo.update!()
  end

  # A presença de quem não tem LiveView: um processo qualquer cuja morte tira a
  # pessoa da lista de conectados, como o fechamento de uma aba faria. O teste
  # assina o tópico para esperar o aviso de presença, em vez de dormir.
  defp connect_participant(%Participant{} = participant) do
    {:ok, connection} = Agent.start(fn -> :connected end)
    # O `on_exit` roda em outro processo, sem a caixa de mensagens do teste:
    # aqui só se garante que a conexão não sobrevive ao teste.
    on_exit(fn -> Process.exit(connection, :kill) end)

    :ok = Games.subscribe(participant.game_session_id)
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

  # Devolve as credenciais como o navegador as apresentaria na requisição
  # seguinte: o cookie escrito na resposta volta como cookie de requisição.
  defp remaining_tokens(conn) do
    case conn.resp_cookies[@cookie] do
      %{max_age: 0} ->
        %{}

      %{value: value} ->
        conn
        |> recycle()
        |> Map.replace!(:secret_key_base, LiveQuizWeb.Endpoint.config(:secret_key_base))
        |> Plug.Test.put_req_cookie(@cookie, value)
        |> ParticipantAuth.read_tokens()

      _absent ->
        %{}
    end
  end
end
