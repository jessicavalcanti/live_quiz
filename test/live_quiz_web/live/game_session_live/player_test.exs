defmodule LiveQuizWeb.GameSessionLive.PlayerTest do
  # A presença e a própria LiveView vivem em processos diferentes do teste,
  # então a sandbox precisa ser compartilhada: uma corrida assíncrona não
  # emprestaria conexão a nenhum deles.
  use LiveQuizWeb.ConnCase, async: false

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import LiveQuiz.QuizzesFixtures
  import Phoenix.LiveViewTest

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Accounts.User
  alias LiveQuiz.Games
  alias LiveQuiz.Games.Answer
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

    test "voltar depois do início mostra a partida, não o lobby", %{
      conn: conn,
      session: session
    } do
      start_room(session)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      assert lv |> element("#match-pending") |> render() =~ "A partida vai começar"
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

      assert rendered =~ "Partida finalizada"
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

      start_room(session)

      assert lv |> element("#match-pending") |> render() =~ "A partida vai começar"
      refute has_element?(lv, "#waiting-notice")
      refute has_element?(lv, "#participants")
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

    test "um início adiantado não encerra a sala nem inventa uma partida", %{
      conn: conn,
      session: session
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      # A sala ainda espera no banco: uma mensagem que chegou antes da
      # transação não pode virar nem partida nem tela de encerramento.
      send(lv.pid, {:game_started, %{session | status: :in_progress}})

      assert has_element?(lv, "#participants")
      refute has_element?(lv, "#room-closed")
      refute has_element?(lv, "#current-question")
      refute has_element?(lv, "#match-pending")
    end

    test "o lobby recusa o evento de resposta forçado à mão", %{
      conn: conn,
      session: session,
      participant: participant
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      render_click(lv, "answer", %{"option_id" => "1"})

      assert answers_of(participant) == []
      assert has_element?(lv, "#waiting-notice")
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

  describe "perguntas e duração no lobby" do
    test "anuncia quantas perguntas e quanto tempo cada uma dura", %{conn: conn} do
      session = room_with_questions(10, 20)
      {:ok, _participant, token} = join(session, "Ana")
      conn = put_participant_token(conn, session.join_code, token)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      assert lv |> element("#match-setup") |> render() =~
               "10 perguntas · 20 segundos por pergunta"
    end

    test "usa o singular quando a sala tem uma pergunta só", %{conn: conn} do
      session = room_with_questions(1, 10)
      {:ok, _participant, token} = join(session, "Ana")
      conn = put_participant_token(conn, session.join_code, token)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      assert lv |> element("#match-setup") |> render() =~
               "1 pergunta · 10 segundos por pergunta"
    end

    test "não oferece nenhum controle para mudar a duração", %{conn: conn} do
      session = room_with_questions(3, 60)
      {:ok, _participant, token} = join(session, "Ana")
      conn = put_participant_token(conn, session.join_code, token)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      refute has_element?(lv, ~s{[name*="question_duration_seconds"]})
      refute has_element?(lv, ~s{[type="radio"]})
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

  describe "pergunta aberta" do
    setup :match_with_ana

    test "antes do primeiro avanço, a tela diz que a partida vai começar", %{
      conn: conn,
      session: session
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      assert lv |> element("#match-pending") |> render() =~ "A partida vai começar"
      refute has_element?(lv, "#current-question")
      refute has_element?(lv, "#question-waiting")
    end

    test "o avanço do host traz enunciado, posição e as quatro alternativas", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      advance(scope, session)

      assert lv |> element("#question-progress") |> render() =~ "Pergunta 1 de 3"
      assert lv |> element("#question-text") |> render() =~ "Pergunta 1 da partida"
      assert has_element?(lv, "#question-countdown-1")

      options = snapshot_options(session, 1)

      assert length(options) == 4

      for option <- options do
        assert lv |> element("#option-#{option.id}") |> render() =~ option.text
      end
    end

    test "nenhum vestígio do gabarito chega ao HTML com a pergunta aberta", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      advance(scope, session)
      render_click(lv, "answer", %{"option_id" => to_string(option_at(session, 1, 2).id)})

      html = render(lv)

      refute html =~ "correct"
      refute html =~ "correta"
      refute html =~ "correto"
      refute html =~ "errada"
      refute html =~ "gabarito"
    end

    test "responder grava a escolha e destaca a alternativa", %{
      conn: conn,
      session: session,
      scope: scope,
      participant: participant
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      chosen = option_at(session, 1, 2)

      render_click(lv, "answer", %{"option_id" => to_string(chosen.id)})

      assert [%Answer{game_session_answer_option_id: id}] = answers_of(participant)
      assert id == chosen.id
      assert lv |> element("#option-#{chosen.id}") |> render() =~ "sua resposta"
      assert has_element?(lv, ~s{#option-#{chosen.id}[aria-pressed="true"]})
    end

    test "o destaque vem da confirmação do servidor, não do toque", %{
      conn: conn,
      session: session,
      scope: scope,
      participant: participant
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      advance(scope, session)
      # A alternativa é de outra pergunta: o servidor recusa e a tela não pode
      # marcar aquilo que ela mesma acabou de mandar.
      stranger = option_at(session, 2, 1)

      render_click(lv, "answer", %{"option_id" => to_string(stranger.id)})

      assert answers_of(participant) == []
      refute has_element?(lv, ~s{#question-options [aria-pressed="true"]})
      assert lv |> element("#answer-notice") |> render() =~ "Não foi possível registrar"
    end

    test "trocar de alternativa segue a última confirmação, sem duplicar resposta", %{
      conn: conn,
      session: session,
      scope: scope,
      participant: participant
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      first = option_at(session, 1, 2)
      second = option_at(session, 1, 3)
      third = option_at(session, 1, 4)

      render_click(lv, "answer", %{"option_id" => to_string(first.id)})
      render_click(lv, "answer", %{"option_id" => to_string(second.id)})

      assert lv |> element("#option-#{second.id}") |> render() =~ "sua resposta"
      refute lv |> element("#option-#{first.id}") |> render() =~ "sua resposta"

      render_click(lv, "answer", %{"option_id" => to_string(third.id)})

      assert lv |> element("#option-#{third.id}") |> render() =~ "sua resposta"
      refute lv |> element("#option-#{second.id}") |> render() =~ "sua resposta"
      assert [%Answer{game_session_answer_option_id: id}] = answers_of(participant)
      assert id == third.id
    end

    test "um id que não é id nenhum não vira resposta nem aviso", %{
      conn: conn,
      session: session,
      scope: scope,
      participant: participant
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      advance(scope, session)

      render_click(lv, "answer", %{"option_id" => "não é id"})

      assert answers_of(participant) == []
      refute has_element?(lv, "#answer-notice")
    end

    test "a resposta fora do prazo vira aviso e leva ao estado de espera", %{
      conn: conn,
      session: session,
      scope: scope,
      participant: participant
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      chosen = option_at(session, 1, 2)
      # O prazo é movido para trás sem que a tela saiba: é exatamente o toque
      # que sai de um celular que ainda mostrava a pergunta correndo.
      ending_in(session, -1)

      render_click(lv, "answer", %{"option_id" => to_string(chosen.id)})

      assert answers_of(participant) == []
      assert lv |> element("#answer-notice") |> render() =~ "O tempo desta pergunta acabou"
      assert has_element?(lv, "#question-waiting")
      refute has_element?(lv, "#current-question")
    end

    test "o toque depois do fechamento vira aviso, sem gravar nada", %{
      conn: conn,
      session: session,
      scope: scope,
      participant: participant
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      close_question!(scope, session)

      render_click(lv, "answer", %{"option_id" => to_string(option_at(session, 1, 2).id)})

      assert answers_of(participant) == []
      assert lv |> element("#answer-notice") |> render() =~ "Esta pergunta foi encerrada"
      assert has_element?(lv, "#question-waiting")
    end

    test "antes do primeiro avanço, o evento de resposta é ignorado", %{
      conn: conn,
      session: session,
      participant: participant
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      # Não há pergunta nenhuma, e o botão não está na tela — mas o evento
      # pode ser empurrado à mão do mesmo jeito.
      render_click(lv, "answer", %{"option_id" => "1"})

      assert answers_of(participant) == []
      refute has_element?(lv, "#answer-notice")
      assert has_element?(lv, "#match-pending")
    end

    test "o evento de resposta sem alternativa nenhuma é ignorado", %{
      conn: conn,
      session: session,
      scope: scope,
      participant: participant
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      advance(scope, session)
      render_click(lv, "answer", %{})

      assert answers_of(participant) == []
      refute has_element?(lv, "#answer-notice")
    end

    test "a tela que perdeu o acesso recusa o evento de resposta", %{
      conn: conn,
      session: session,
      scope: scope,
      token: token,
      participant: participant
    } do
      {:ok, phone, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)

      desktop_conn = put_participant_token(build_conn(), session.join_code, token)
      {:ok, _desktop, _html} = live(desktop_conn, ~p"/game-sessions/#{session.join_code}")

      assert has_element?(phone, "#access-lost-notice")

      render_click(phone, "answer", %{"option_id" => to_string(option_at(session, 1, 2).id)})

      assert answers_of(participant) == []
    end

    test "quem já saiu da sala não responde mais", %{
      conn: conn,
      session: session,
      scope: scope,
      participant: participant
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      lv |> element("#leave-form") |> render_submit()

      render_click(lv, "answer", %{"option_id" => to_string(option_at(session, 1, 2).id)})

      assert answers_of(participant) == []
    end

    test "a partida finalizada por baixo dos panos vira o encerramento", %{
      conn: conn,
      session: session,
      scope: scope,
      participant: participant
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      # A partida acaba sem passar pelo evento da sala: o toque que já estava a
      # caminho não pode virar resposta de uma partida encerrada.
      Repo.update!(GameSession.status_changeset(session, :finished))

      render_click(lv, "answer", %{"option_id" => to_string(option_at(session, 1, 2).id)})

      assert answers_of(participant) == []
      assert lv |> element("#room-closed") |> render() =~ "Partida finalizada"
    end

    test "as alternativas são botões, com a escolha e a contagem anunciadas", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      chosen = option_at(session, 1, 2)

      assert has_element?(lv, ~s{#question-countdown-1[role="timer"]})
      assert has_element?(lv, ~s{button#option-#{chosen.id}[aria-pressed="false"]})

      render_click(lv, "answer", %{"option_id" => to_string(chosen.id)})

      assert has_element?(lv, ~s{button#option-#{chosen.id}[aria-pressed="true"]})
    end
  end

  describe "espera entre perguntas" do
    setup :match_with_ana

    test "a pergunta encerrada pelo host leva à espera, sem alternativas", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      close_question!(scope, session)

      rendered = lv |> element("#question-waiting") |> render()

      assert rendered =~ "Pergunta 1 de 3"
      assert rendered =~ "Pergunta encerrada"
      assert rendered =~ "Aguarde"
      refute has_element?(lv, "#question-options")
    end

    test "a pergunta encerrada pelo prazo leva à espera", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = scope |> advance(session) |> ending_in(-1)
      {:ok, _closed} = Games.close_question_by_timeout(session.id)

      assert has_element?(lv, "#question-waiting")
      refute has_element?(lv, "#current-question")
    end

    test "a última resposta que faltava fecha a pergunta e leva à espera", %{
      conn: conn,
      session: session,
      scope: scope,
      bruno: bruno
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      {:ok, _answer} = Games.answer_question(bruno, option_at(session, 1, 1).id, [])

      render_click(lv, "answer", %{"option_id" => to_string(option_at(session, 1, 2).id)})

      assert Repo.get!(GameSession, session.id).current_question_closed_at != nil
      assert has_element?(lv, "#question-waiting")
    end

    test "a pergunta seguinte troca o enunciado e limpa a escolha anterior", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      render_click(lv, "answer", %{"option_id" => to_string(option_at(session, 1, 2).id)})

      scope |> close_question!(session) |> then(&advance(scope, &1, 1))

      assert lv |> element("#question-progress") |> render() =~ "Pergunta 2 de 3"
      assert lv |> element("#question-text") |> render() =~ "Pergunta 2 da partida"
      refute has_element?(lv, ~s{#question-options [aria-pressed="true"]})
    end

    test "o aviso da recusa some quando a pergunta seguinte abre", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      close_question!(scope, session)
      render_click(lv, "answer", %{"option_id" => to_string(option_at(session, 1, 2).id)})

      assert has_element?(lv, "#answer-notice")

      advance(scope, Repo.get!(GameSession, session.id), 1)

      refute has_element?(lv, "#answer-notice")
    end
  end

  describe "revelação do resultado da pergunta" do
    setup :match_with_ana

    test "não revela nada enquanto a pergunta está aberta", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      advance(scope, session)

      assert has_element?(lv, "#question-options")
      refute has_element?(lv, "#question-results")
    end

    test "quem acertou vê o próprio acerto e a distribuição das alternativas", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      render_click(lv, "answer", %{"option_id" => to_string(option_at(session, 1, 1).id)})
      close_question!(scope, session)

      rendered = lv |> element("#question-results") |> render()

      assert rendered =~ "Você acertou!"

      for option <- snapshot_options(session, 1) do
        assert rendered =~ option.text
      end
    end

    test "quem errou vê o próprio erro e a alternativa correta destacada", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      chosen = option_at(session, 1, 2)
      render_click(lv, "answer", %{"option_id" => to_string(chosen.id)})
      close_question!(scope, session)

      assert lv |> element("#question-results") |> render() =~ "Você errou"
      assert lv |> element("#result-option-#{chosen.id}") |> render() =~ "sua resposta"

      assert lv
             |> element("#result-option-#{option_at(session, 1, 1).id}")
             |> render() =~ "Resposta correta"
    end

    test "quem não respondeu lê exatamente isso", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      close_question!(scope, session)

      rendered = lv |> element("#question-results") |> render()

      assert rendered =~ "Você não respondeu"
      refute rendered =~ "sua resposta"
    end

    test "a alternativa que ninguém escolheu continua na lista, com zero", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      render_click(lv, "answer", %{"option_id" => to_string(option_at(session, 1, 1).id)})
      close_question!(scope, session)

      ignored = option_at(session, 1, 4)

      assert lv |> element("#result-option-#{ignored.id}") |> render() =~ ignored.text
      assert lv |> element("#result-option-#{ignored.id}") |> render() =~ "0 respostas · 0%"
    end

    test "conta quem deixou a pergunta passar", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      render_click(lv, "answer", %{"option_id" => to_string(option_at(session, 1, 1).id)})
      close_question!(scope, session)

      assert lv |> element("#no-answer-count") |> render() =~ "1 pessoa não respondeu"
    end

    test "o painel some quando o host avança para a pergunta seguinte", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      close_question!(scope, session)

      assert has_element?(lv, "#question-results")

      advance(scope, Repo.get!(GameSession, session.id), 1)

      refute has_element?(lv, "#question-results")
      assert lv |> element("#question-progress") |> render() =~ "Pergunta 2 de 3"
    end

    test "quem entra com a pergunta encerrada cai no painel daquela pergunta", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      session = advance(scope, session)
      session = scope |> close_question!(session) |> then(&advance(scope, &1, 1))
      session = scope |> close_question!(session) |> then(&advance(scope, &1, 2))
      close_question!(scope, session)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      assert lv |> element("#question-progress") |> render() =~ "Pergunta 3 de 3"
      assert has_element?(lv, "#question-results")
      assert lv |> element("#question-results") |> render() =~ "Você não respondeu"
    end

    test "a espera continua sozinha quando o prazo venceu mas a apuração ainda não existe", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      ending_in(session, -1)
      send(lv.pid, {:presence_changed, session.id})

      assert has_element?(lv, "#question-waiting")
      refute has_element?(lv, "#question-results")
    end
  end

  describe "tela de encerramento" do
    setup :match_with_ana

    test "a partida finalizada informa quantas perguntas foram aplicadas", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      session = scope |> close_question!(session) |> then(&advance(scope, &1, 1))
      {:ok, _finished} = Games.finish_game_session(scope, session)

      rendered = lv |> element("#room-closed") |> render()

      assert rendered =~ "Partida finalizada"
      assert rendered =~ "Perguntas aplicadas: 2 de 3"
      assert has_element?(lv, "#back-to-join")
    end

    test "a tela final mostra pontuação, posição e ranking", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      render_click(lv, "answer", %{"option_id" => to_string(option_at(session, 1, 1).id)})
      {:ok, _finished} = Games.finish_game_session(scope, session)

      rendered = lv |> element("#room-closed") |> render()

      assert rendered =~ "pontos"
      assert rendered =~ "posição"
      assert rendered =~ "Resultado final"
      assert rendered =~ "acertos"
    end

    test "o cancelamento reaproveita a tela com a mensagem da fase 2", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      {:ok, _cancelled} = Games.cancel_game_session(scope, session)

      rendered = lv |> element("#room-closed") |> render()

      assert rendered =~ "Sala cancelada pelo host"
      assert rendered =~ "Perguntas aplicadas: 1 de 3"
      assert has_element?(lv, "#back-to-join")
    end

    test "a expiração reaproveita a tela com a mensagem da ausência", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      {:ok, _expired} = Games.expire_game_session(session)

      assert lv |> element("#room-closed") |> render() =~ "ausência do host"
    end

    test "quem volta depois do fim ainda lê o que a partida aplicou", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      session = advance(scope, session)
      {:ok, _finished} = Games.finish_game_session(scope, session)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      rendered = lv |> element("#room-closed") |> render()

      assert rendered =~ "Partida finalizada"
      assert rendered =~ "Perguntas aplicadas: 1 de 3"
    end
  end

  describe "reentrada durante a partida" do
    setup :match_with_ana

    test "recarregar no meio da pergunta devolve pergunta, escolha e contagem", %{
      conn: conn,
      session: session,
      scope: scope,
      participant: participant
    } do
      session = advance(scope, session)
      session = scope |> close_question!(session) |> then(&advance(scope, &1, 1))
      chosen = option_at(session, 2, 2)
      {:ok, _answer} = Games.answer_question(participant, chosen.id, [])

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      assert lv |> element("#question-progress") |> render() =~ "Pergunta 2 de 3"
      assert lv |> element("#option-#{chosen.id}") |> render() =~ "sua resposta"
      assert has_element?(lv, "#question-countdown-2")
    end

    test "quem volta sem ter respondido pode responder, com o tempo que sobrou", %{
      conn: conn,
      session: session,
      scope: scope,
      participant: participant
    } do
      session = advance(scope, session)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      refute has_element?(lv, ~s{#question-options [aria-pressed="true"]})

      chosen = option_at(session, 1, 3)
      render_click(lv, "answer", %{"option_id" => to_string(chosen.id)})

      assert [%Answer{game_session_answer_option_id: id}] = answers_of(participant)
      assert id == chosen.id
    end

    test "quem volta com a pergunta já encerrada vê o encerramento dela", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      session = advance(scope, session)
      close_question!(scope, session)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      assert lv |> element("#question-waiting") |> render() =~ "Pergunta 1 de 3"
      refute has_element?(lv, "#current-question")
    end

    test "quem volta com a partida finalizada vê a tela de encerramento", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      session = advance(scope, session)
      {:ok, _finished} = Games.finish_game_session(scope, session)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      assert lv |> element("#room-closed") |> render() =~ "Partida finalizada"
    end

    test "sem credencial, a partida em andamento também manda para a entrada", %{
      session: session
    } do
      assert {:error, {:redirect, %{to: path}}} =
               live(build_conn(), ~p"/game-sessions/#{session.join_code}")

      assert path == ~p"/join?code=#{session.join_code}"
    end

    test "abrir a mesma participação em outro aparelho transfere a partida", %{
      conn: conn,
      session: session,
      scope: scope,
      token: token
    } do
      {:ok, phone, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      chosen = option_at(session, 1, 2)
      render_click(phone, "answer", %{"option_id" => to_string(chosen.id)})

      desktop_conn = put_participant_token(build_conn(), session.join_code, token)
      {:ok, desktop, _html} = live(desktop_conn, ~p"/game-sessions/#{session.join_code}")

      assert has_element?(phone, "#access-lost-notice")
      assert desktop |> element("#question-progress") |> render() =~ "Pergunta 1 de 3"
      assert desktop |> element("#option-#{chosen.id}") |> render() =~ "sua resposta"
    end
  end

  describe "sala e partida durante a execução" do
    setup :match_with_ana

    test "o aviso de host desconectado aparece sem parar a pergunta", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      advance(scope, session)
      send(lv.pid, {:host_disconnected, DateTime.truncate(DateTime.utc_now(), :second)})

      assert lv |> element("#host-away-notice") |> render() =~ "O host está desconectado"
      assert has_element?(lv, "#current-question")

      send(lv.pid, {:host_connected, nil})

      refute has_element?(lv, "#host-away-notice")
    end

    test "sair da sala continua disponível durante a pergunta", %{
      conn: conn,
      session: session,
      scope: scope,
      participant: participant
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      advance(scope, session)

      assert has_element?(lv, "#leave-room")

      lv |> element("#leave-form") |> render_submit()

      assert Repo.get!(Participant, participant.id).left_at != nil
    end

    test "a partida finalizada pelo host leva à tela de encerramento", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      advance(scope, session)
      {:ok, _finished} = Games.finish_game_session(scope, session)

      assert lv |> element("#room-closed") |> render() =~ "Partida finalizada"
      refute has_element?(lv, "#current-question")
    end

    test "a sala cancelada no meio da pergunta explica o cancelamento", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      advance(scope, session)
      {:ok, _cancelled} = Games.cancel_game_session(scope, session)

      assert lv |> element("#room-closed") |> render() =~ "Sala cancelada pelo host"
    end

    test "a contagem de respostas dos outros não aparece para quem joga", %{
      conn: conn,
      session: session,
      scope: scope,
      bruno: bruno
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}")

      session = advance(scope, session)
      {:ok, _answer} = Games.answer_question(bruno, option_at(session, 1, 1).id, [])

      html = render(lv)

      refute html =~ "Respostas:"
      assert has_element?(lv, "#current-question")
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

  # Uma sala esperando cujo quiz tem um número de perguntas escolhido pelo
  # teste: o lobby anuncia esse número, e o fixture padrão traz só uma.
  defp room_with_questions(question_count, duration_seconds) do
    host = user_fixture()
    scope = Scope.for_user(host)
    quiz = quiz_fixture(scope, %{title: "Geografia"})

    for _ <- 1..question_count, do: question_fixture(scope, quiz)

    game_session_fixture(%{
      host: host,
      quiz: quiz,
      status: :waiting,
      question_duration_seconds: duration_seconds
    })
  end

  # Uma partida de três perguntas já congelada, parada antes do primeiro avanço,
  # com "Ana" dentro e a credencial dela no navegador. "Bruno" entra conectado
  # de propósito: com uma pessoa só na sala, a primeira resposta seria sempre a
  # última que faltava e fecharia a pergunta — a apuração automática tem cenário
  # próprio.
  defp match_with_ana(%{conn: conn}) do
    host = user_fixture()
    scope = Scope.for_user(host)
    quiz = quiz_fixture(scope, %{title: "Geografia"})

    for position <- 1..3 do
      question_fixture(scope, quiz, %{text: "Pergunta #{position} da partida"})
    end

    session = game_session_fixture(%{host: host, quiz: quiz, status: :waiting})
    {:ok, ana, token} = join(session, "Ana")
    bruno = participant_fixture(session, %{nickname: "Bruno"})
    connect_participant(bruno)

    {:ok, session} = Games.start_game_session(scope, session, 2)

    %{
      conn: put_participant_token(conn, session.join_code, token),
      session: session,
      participant: ana,
      bruno: bruno,
      token: token,
      scope: scope,
      host: host
    }
  end

  defp advance(scope, %GameSession{} = session, expected \\ nil) do
    {:ok, advanced} = Games.advance_question(scope, session, expected)

    advanced
  end

  defp close_question!(scope, %GameSession{} = session) do
    {:ok, closed} = Games.close_question(scope, session)

    closed
  end

  defp snapshot_options(%GameSession{} = session, position) do
    {:ok, question} = Games.get_snapshot_question(session, position)

    Enum.sort_by(question.answer_options, & &1.position)
  end

  defp option_at(%GameSession{} = session, position, index) do
    session |> snapshot_options(position) |> Enum.at(index - 1)
  end

  defp answers_of(%Participant{id: id}) do
    Answer |> Repo.all() |> Enum.filter(&(&1.participant_id == id))
  end

  # As colunas da pergunta corrente não têm changeset de propósito — mover a
  # partida de uma pergunta para a outra é papel do contexto —, então o teste
  # que precisa de um prazo específico escreve direto.
  defp ending_in(%GameSession{} = session, seconds) do
    started_at =
      DateTime.utc_now()
      |> DateTime.add(seconds, :second)
      |> DateTime.add(-session.question_duration_seconds, :second)

    session
    |> Ecto.Changeset.change(%{
      current_question_started_at: started_at,
      current_question_ends_at:
        DateTime.add(started_at, session.question_duration_seconds, :second)
    })
    |> Repo.update!()
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
