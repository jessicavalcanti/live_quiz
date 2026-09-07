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

    test "confirma a cópia do link", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert lv |> element("#copy-link") |> render_click() =~ "Link copiado"
    end

    test "mostra código, link e QR code de entrada", %{conn: conn, session: session} do
      url = LiveQuizWeb.ShareSession.join_url(session.join_code)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert lv |> element("#join-code") |> render() =~ session.join_code
      assert lv |> element("#join-url") |> render() =~ url
      assert has_element?(lv, "#copy-link")
      assert has_element?(lv, "#join-qr-code svg")
    end

    test "o QR code do lobby é o desta sala, e não o de outra", %{conn: conn, session: session} do
      other = game_session_fixture()

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")
      rendered = lv |> element("#join-qr-code") |> render()

      assert rendered =~ "QR code com o link de entrada da sala #{session.join_code}"
      assert rendered =~ "<svg"
      refute rendered =~ other.join_code
      refute rendered =~ "<img"
    end

    test "o bloco de compartilhamento some quando a partida começa", %{
      conn: conn,
      session: session,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      participant = participant_fixture(session)
      {:ok, _participant, _connection_id} = Games.claim_participant_connection(participant)
      {:ok, _session} = Games.start_game_session(scope, session, 1)

      render(lv)

      refute has_element?(lv, "#share-session")
    end
  end

  describe "perguntas e duração no lobby" do
    setup :register_and_log_in_user

    test "anuncia quantas perguntas e quanto tempo cada uma dura", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      quiz = quiz_fixture(scope, %{title: "Geografia"})
      for _ <- 1..10, do: question_fixture(scope, quiz)

      session =
        game_session_fixture(%{
          host: user,
          quiz: quiz,
          status: :waiting,
          question_duration_seconds: 20
        })

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert lv |> element("#match-setup") |> render() =~
               "10 perguntas · 20 segundos por pergunta"
    end

    test "usa o singular quando o quiz tem uma pergunta só", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      quiz = quiz_fixture(scope, %{title: "Geografia"})
      question_fixture(scope, quiz)

      session =
        game_session_fixture(%{
          host: user,
          quiz: quiz,
          status: :waiting,
          question_duration_seconds: 60
        })

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert lv |> element("#match-setup") |> render() =~
               "1 pergunta · 60 segundos por pergunta"
    end

    test "conta as perguntas do snapshot depois que a partida começa", %{
      conn: conn,
      user: user,
      scope: scope
    } do
      quiz = quiz_fixture(scope, %{title: "Geografia"})
      for _ <- 1..3, do: question_fixture(scope, quiz)

      session = game_session_fixture(%{host: user, quiz: quiz, status: :waiting})
      :ok = Games.subscribe(session.id)
      session |> participant_fixture() |> connect_participant()

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      lv |> element("#start-game") |> render_click()

      assert Games.snapshot_question_count(session) == 3
      assert lv |> element("#match-setup") |> render() =~ "3 perguntas"
    end

    test "não oferece nenhum controle para mudar a duração", %{conn: conn, user: user} do
      session = game_session_fixture(%{host: user, status: :waiting})

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      refute has_element?(lv, ~s{[name*="question_duration_seconds"]})
      refute has_element?(lv, ~s{[type="radio"]})
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

      assert html =~ "Pronto para começar"
      assert has_element?(lv, "#match")
      assert has_element?(lv, "#match-pending")
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
      assert has_element?(lv, "#share-session")
    end

    test "o evento de início chegado de outra aba atualiza a tela", %{
      conn: conn,
      user: user,
      session: session
    } do
      session |> participant_fixture() |> connect_participant()

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      {:ok, _started} = Games.start_game_session(Scope.for_user(user), session, 1)

      assert has_element?(lv, "#match-pending")
      refute has_element?(lv, "#start-game")
    end
  end

  describe "tela da partida" do
    setup [:register_and_log_in_user, :running_room]

    test "antes do primeiro avanço a tela fica pronta para começar", %{
      conn: conn,
      session: session
    } do
      {:ok, lv, html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert html =~ "Pronto para começar"
      assert has_element?(lv, "#match")
      assert has_element?(lv, "#match-pending")
      refute has_element?(lv, "#current-question")
      refute has_element?(lv, "#share-session")
      refute has_element?(lv, "#start-game")
    end

    test "a pergunta aberta traz posição, enunciado, alternativas e gabarito", %{
      conn: conn,
      scope: scope,
      session: session,
      questions: [first | _rest]
    } do
      {:ok, _open} = Games.advance_question(scope, session, nil)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert lv |> element("#question-progress") |> render() =~ "Pergunta 1 de 3"
      assert lv |> element("#question-text") |> render() =~ "Pergunta 1 da partida"

      [correct | wrong] = Enum.sort_by(first.answer_options, & &1.position)

      for option <- first.answer_options do
        assert lv |> element("#option-#{option.id}") |> render() =~ option.text
      end

      assert lv |> element("#option-#{correct.id}") |> render() =~ "Resposta correta"

      for option <- wrong do
        refute lv |> element("#option-#{option.id}") |> render() =~ "Resposta correta"
      end
    end

    test "a contagem é desenhada a partir do prazo absoluto do servidor", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      {:ok, open} = Games.advance_question(scope, session, nil)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      countdown = lv |> element("#question-countdown-1") |> render()

      assert countdown =~ DateTime.to_iso8601(open.current_question_ends_at)
      assert countdown =~ ~s(role="timer")
    end

    test "recarregar no meio da pergunta reconstrói o tempo que resta", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      {:ok, open} = Games.advance_question(scope, session, nil)
      ending_in(open, 12)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert lv |> element("#question-progress") |> render() =~ "Pergunta 1 de 3"
      assert lv |> element("#question-countdown-1") |> render() =~ ~r/>\s*0:1[12]\s*</
    end

    test "o host que volta na pergunta 3 cai direto nela", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      play_to(scope, session, 3)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert lv |> element("#question-progress") |> render() =~ "Pergunta 3 de 3"
      assert has_element?(lv, "#question-countdown-3")
    end

    test "o contador de respostas sobe com as respostas que chegam", %{
      conn: conn,
      scope: scope,
      session: session,
      questions: [first | _rest]
    } do
      [one, two, _three] =
        for index <- 1..3, do: participant_fixture(session, %{nickname: "P#{index}"})

      [option | _rest] = first.answer_options
      {:ok, _open} = Games.advance_question(scope, session, nil)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert answers_counter(lv) == "Respostas: 0 / 3"

      {:ok, _answer} = Games.answer_question(one, option.id, [])
      assert answers_counter(lv) == "Respostas: 1 / 3"

      {:ok, _answer} = Games.answer_question(two, option.id, [])
      assert answers_counter(lv) == "Respostas: 2 / 3"
    end

    test "o contador redesenha o número que o evento de resposta carrega", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      for index <- 1..3, do: participant_fixture(session, %{nickname: "P#{index}"})
      {:ok, _open} = Games.advance_question(scope, session, nil)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      send(lv.pid, {:answer_submitted, session.id, 2})

      assert answers_counter(lv) == "Respostas: 2 / 3"
    end

    test "quem saiu da sala não conta no denominador", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      [_one, _two, three] =
        for index <- 1..3, do: participant_fixture(session, %{nickname: "P#{index}"})

      {:ok, _left} = Games.leave_game_session(three)
      {:ok, _open} = Games.advance_question(scope, session, nil)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert answers_counter(lv) == "Respostas: 0 / 2"
    end
  end

  describe "controles da partida" do
    setup [:register_and_log_in_user, :running_room]

    test "antes do primeiro avanço só avançar comanda alguma coisa", %{
      conn: conn,
      session: session
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert has_element?(lv, "#close-question[disabled]")
      refute has_element?(lv, "#advance-question[disabled]")
      refute has_element?(lv, "#finish-game[disabled]")
      refute has_element?(lv, "#finish-game.btn-success")
    end

    test "com a pergunta aberta só encerrar fica habilitado", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      {:ok, _open} = Games.advance_question(scope, session, nil)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      refute has_element?(lv, "#close-question[disabled]")
      assert has_element?(lv, "#advance-question[disabled]")
      assert has_element?(lv, ~s{#advance-question[aria-disabled="true"]})
      refute has_element?(lv, "#finish-game[disabled]")
    end

    test "com a pergunta encerrada só avançar volta a comandar", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      {:ok, open} = Games.advance_question(scope, session, nil)
      {:ok, _closed} = Games.close_question(scope, open)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert has_element?(lv, "#close-question[disabled]")
      refute has_element?(lv, "#advance-question[disabled]")
      refute has_element?(lv, "#question-countdown-1")
      assert has_element?(lv, "#question-closed-badge")
    end

    test "na última pergunta encerrada avançar sai de cena e finalizar ganha destaque", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      last = play_to(scope, session, 3)
      {:ok, _closed} = Games.close_question(scope, last)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert has_element?(lv, "#advance-question[disabled]")
      assert has_element?(lv, "#close-question[disabled]")
      assert has_element?(lv, "#finish-game.btn-success")
    end

    test "encerrar pela tela para a contagem e libera o avanço", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      {:ok, _open} = Games.advance_question(scope, session, nil)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      lv |> element("#close-question") |> render_click()

      assert has_element?(lv, "#question-closed-badge")
      refute has_element?(lv, "#question-countdown-1")
      assert has_element?(lv, "#close-question[disabled]")
      refute has_element?(lv, "#advance-question[disabled]")

      assert Repo.get!(GameSession, session.id).current_question_closed_at
    end

    test "avançar leva a posição corrente e abre a pergunta seguinte", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      {:ok, open} = Games.advance_question(scope, session, nil)
      {:ok, _closed} = Games.close_question(scope, open)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert has_element?(lv, ~s{#advance-question[phx-value-position="1"]})

      lv |> element("#advance-question") |> render_click()

      assert lv |> element("#question-progress") |> render() =~ "Pergunta 2 de 3"
      assert Repo.get!(GameSession, session.id).current_question_position == 2
    end

    test "o primeiro avanço vai sem posição nenhuma", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      refute has_element?(lv, "#advance-question[phx-value-position]")

      lv |> element("#advance-question") |> render_click()

      assert Repo.get!(GameSession, session.id).current_question_position == 1
    end

    test "o duplo clique em avançar não pula pergunta", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      {:ok, open} = Games.advance_question(scope, session, nil)
      {:ok, _closed} = Games.close_question(scope, open)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      render_click(lv, "advance_question", %{"position" => "1"})
      render_click(lv, "advance_question", %{"position" => "1"})

      assert Repo.get!(GameSession, session.id).current_question_position == 2
      assert lv |> element("#question-progress") |> render() =~ "Pergunta 2 de 3"
    end

    test "um avanço com posição de outra pergunta não anda", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      {:ok, open} = Games.advance_question(scope, session, nil)
      {:ok, _closed} = Games.close_question(scope, open)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      render_click(lv, "advance_question", %{"position" => "3"})

      assert Repo.get!(GameSession, session.id).current_question_position == 1
    end

    test "um avanço com posição forjada não anda", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      {:ok, open} = Games.advance_question(scope, session, nil)
      {:ok, _closed} = Games.close_question(scope, open)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      render_click(lv, "advance_question", %{"position" => "não é posição"})

      assert Repo.get!(GameSession, session.id).current_question_position == 1
    end

    test "um avanço forçado depois da última pergunta explica que acabou", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      last = play_to(scope, session, 3)
      {:ok, _closed} = Games.close_question(scope, last)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      html = render_click(lv, "advance_question", %{"position" => "3"})

      assert html =~ "Esta era a última pergunta"
      assert Repo.get!(GameSession, session.id).current_question_position == 3
    end

    test "um encerramento forçado antes da primeira pergunta avisa sem quebrar", %{
      conn: conn,
      session: session
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert render_click(lv, "close_question", %{}) =~ "Não há pergunta aberta para encerrar"
    end

    test "comandar uma partida encerrada por trás da tela avisa sem quebrar", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      {:ok, _open} = Games.advance_question(scope, session, nil)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      # A partida termina sem passar pelo contexto, então nenhum evento chega ao
      # LiveView: é a corrida entre o clique do host e o prazo de expiração.
      Repo.update!(GameSession.status_changeset(session, :expired))

      assert render_click(lv, "close_question", %{}) =~
               "Esta sala não está mais no estado necessário"
    end

    test "finalizar pede confirmação e só então encerra a partida", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      {:ok, open} = Games.advance_question(scope, session, nil)
      {:ok, _closed} = Games.close_question(scope, open)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      lv |> element("#finish-game") |> render_click()

      assert has_element?(lv, "#finish-game-modal")
      assert render(lv) =~ "não poderá ser retomada"
      assert Repo.get!(GameSession, session.id).status == :in_progress

      html = lv |> element("#confirm-finish") |> render_click()

      assert html =~ "Partida finalizada"
      assert has_element?(lv, "#room-closed")
      refute has_element?(lv, "#match")
      assert Repo.get!(GameSession, session.id).status == :finished
    end

    test "fechar a confirmação mantém a partida rodando", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      lv |> element("#finish-game") |> render_click()
      lv |> element("#finish-game-modal button", "Continuar jogando") |> render_click()

      refute has_element?(lv, "#finish-game-modal")
      assert has_element?(lv, "#match")
      assert Repo.get!(GameSession, session.id).status == :in_progress
    end

    test "cancelar no meio da partida continua pedindo confirmação", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      {:ok, _open} = Games.advance_question(scope, session, nil)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      lv |> element("#cancel-room") |> render_click()

      assert has_element?(lv, "#cancel-room-modal")
      assert Repo.get!(GameSession, session.id).status == :in_progress

      html = lv |> element("#confirm-cancel") |> render_click()

      assert html =~ "Sala cancelada"
      assert has_element?(lv, "#room-closed")
      assert Repo.get!(GameSession, session.id).status == :cancelled
    end
  end

  describe "eventos da partida" do
    setup [:register_and_log_in_user, :running_room]

    test "o encerramento pelo prazo chega sozinho à tela", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      {:ok, open} = Games.advance_question(scope, session, nil)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert has_element?(lv, "#question-countdown-1")

      ending_in(open, -1)
      {:ok, _closed} = Games.close_question_by_timeout(session.id)

      assert has_element?(lv, "#question-closed-badge")
      refute has_element?(lv, "#question-countdown-1")
      refute has_element?(lv, "#advance-question[disabled]")
    end

    test "o encerramento por todo mundo ter respondido chega sozinho à tela", %{
      conn: conn,
      scope: scope,
      session: session,
      questions: [first | _rest]
    } do
      participants = for index <- 1..3, do: participant_fixture(session, %{nickname: "P#{index}"})
      [option | _rest] = first.answer_options
      {:ok, _open} = Games.advance_question(scope, session, nil)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      connected = Enum.map(participants, & &1.id)

      for participant <- participants do
        {:ok, _answer} = Games.answer_question(participant, option.id, connected)
      end

      assert has_element?(lv, "#question-closed-badge")
      assert answers_counter(lv) == "Respostas: 3 / 3"
    end

    test "o avanço vindo de outra conexão do host atualiza a tela", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert has_element?(lv, "#match-pending")

      {:ok, _open} = Games.advance_question(scope, session, nil)

      assert lv |> element("#question-progress") |> render() =~ "Pergunta 1 de 3"
    end

    test "a partida finalizada em outra conexão leva a tela ao encerramento", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      {:ok, _finished} = Games.finish_game_session(scope, session)

      assert has_element?(lv, "#room-closed")
      assert render(lv) =~ "Partida finalizada"
      refute has_element?(lv, "#match")
    end

    test "o cancelamento no meio da partida leva a tela ao encerramento", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      {:ok, _open} = Games.advance_question(scope, session, nil)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      {:ok, _cancelled} = Games.cancel_game_session(scope, session)

      assert has_element?(lv, "#room-closed")
      assert render(lv) =~ "Sala cancelada"
      refute has_element?(lv, "#match")
    end

    test "a expiração no meio da partida leva a tela ao encerramento", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      {:ok, _open} = Games.advance_question(scope, session, nil)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      {:ok, _expired} = session |> overdue_host_absence() |> Games.expire_game_session()

      assert has_element?(lv, "#room-closed")
      assert render(lv) =~ "Sala encerrada por ausência"
    end
  end

  describe "revelação do resultado da pergunta" do
    setup [:register_and_log_in_user, :running_room]

    test "o painel só aparece depois que a pergunta encerra", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      {:ok, open} = Games.advance_question(scope, session, nil)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert has_element?(lv, "#question-options")
      refute has_element?(lv, "#question-results")

      {:ok, _closed} = Games.close_question(scope, open)

      assert has_element?(lv, "#question-results")
      refute has_element?(lv, "#question-options")
    end

    test "traz a contagem por alternativa e quem não respondeu", %{
      conn: conn,
      scope: scope,
      session: session,
      questions: [first | _rest]
    } do
      [correct, second, third, ignored] = Enum.sort_by(first.answer_options, & &1.position)

      answer_many(session, correct, 15)
      answer_many(session, second, 4)
      answer_many(session, third, 3)
      for index <- 1..3, do: participant_fixture(session, %{nickname: "Ausente #{index}"})

      {:ok, open} = Games.advance_question(scope, session, nil)
      {:ok, _closed} = Games.close_question(scope, open)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert lv |> element("#result-option-#{correct.id}") |> render() =~ "15 respostas · 68%"
      assert lv |> element("#result-option-#{second.id}") |> render() =~ "4 respostas · 18%"
      assert lv |> element("#result-option-#{third.id}") |> render() =~ "3 respostas · 14%"
      assert lv |> element("#result-option-#{ignored.id}") |> render() =~ "0 respostas · 0%"
      assert lv |> element("#no-answer-count") |> render() =~ "3 pessoas não responderam"
    end

    test "destaca a alternativa correta sem marcar acerto pessoal do host", %{
      conn: conn,
      scope: scope,
      session: session,
      questions: [first | _rest]
    } do
      [correct | wrong] = Enum.sort_by(first.answer_options, & &1.position)
      {:ok, open} = Games.advance_question(scope, session, nil)
      {:ok, _closed} = Games.close_question(scope, open)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert lv |> element("#result-option-#{correct.id}") |> render() =~ "Resposta correta"

      for option <- wrong do
        refute lv |> element("#result-option-#{option.id}") |> render() =~ "Resposta correta"
      end

      refute has_element?(lv, "#own-result")
      refute render(lv) =~ "Você acertou"
      refute render(lv) =~ "sua resposta"
    end

    test "o painel some quando o host avança para a pergunta seguinte", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      {:ok, open} = Games.advance_question(scope, session, nil)
      {:ok, _closed} = Games.close_question(scope, open)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert has_element?(lv, "#question-results")

      render_click(lv, "advance_question", %{"position" => "1"})

      refute has_element?(lv, "#question-results")
      assert lv |> element("#question-progress") |> render() =~ "Pergunta 2 de 3"
    end

    test "o encerramento vindo de outra conexão traz o painel sozinho", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      {:ok, open} = Games.advance_question(scope, session, nil)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      refute has_element?(lv, "#question-results")

      {:ok, _closed} = Games.close_question(scope, open)

      assert has_element?(lv, "#question-results")
    end
  end

  describe "tela de encerramento da partida" do
    setup [:register_and_log_in_user, :running_room]

    test "a partida finalizada na última pergunta informa o que foi aplicado", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      played = play_to(scope, session, 3)
      {:ok, _finished} = Games.finish_game_session(scope, played)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      rendered = lv |> element("#room-closed") |> render()

      assert rendered =~ "Partida finalizada"
      assert rendered =~ "Perguntas aplicadas: 3 de 3"
      assert has_element?(lv, ~s{#back-to-quizzes[href="/quizzes"]})
    end

    test "a partida finalizada no meio informa só o que chegou a ser aplicado", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      play_to(scope, session, 1)
      render_click(lv, "open_finish")
      render_click(lv, "confirm_finish")

      rendered = lv |> element("#room-closed") |> render()

      assert rendered =~ "Partida finalizada"
      assert rendered =~ "Perguntas aplicadas: 1 de 3"
      refute has_element?(lv, "#match")
    end

    test "a tela final não fala de pontuação, posição nem ranking", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      played = play_to(scope, session, 2)
      {:ok, _finished} = Games.finish_game_session(scope, played)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      rendered = lv |> element("#room-closed") |> render()

      for palavra <- ["ponto", "Ponto", "posição", "Posição", "ranking", "Ranking", "acerto"] do
        refute rendered =~ palavra
      end
    end

    test "a sala cancelada antes da primeira pergunta não conta pergunta alguma", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      {:ok, _cancelled} = Games.cancel_game_session(scope, session)

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert lv |> element("#room-closed") |> render() =~ "Sala cancelada"
      refute has_element?(lv, "#questions-played")
    end
  end

  describe "acesso à tela da partida" do
    setup [:register_and_log_in_user, :running_room]

    test "a partida de outra pessoa responde 404", %{conn: conn, session: session} do
      %{conn: stranger} = log_in_fresh_user(conn)

      assert_raise Ecto.NoResultsError, fn ->
        live(stranger, ~p"/game-sessions/#{session.join_code}/host")
      end
    end

    test "quem está jogando não entra na tela do host", %{session: session} do
      player = user_fixture()
      participant_fixture(session, %{user: player})

      conn = log_in_user(build_conn(), player)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/game-sessions/#{session.join_code}/host")
      end
    end

    test "a segunda aba assume a partida e a primeira para de comandar", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      {:ok, _open} = Games.advance_question(scope, session, nil)

      {:ok, first, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")
      {:ok, second, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      assert has_element?(first, "#access-lost-notice")
      assert has_element?(first, "#close-question[disabled]")
      assert has_element?(first, "#advance-question[disabled]")
      assert has_element?(first, "#finish-game[disabled]")
      assert has_element?(first, "#cancel-room[disabled]")

      render_click(first, "close_question", %{})
      render_click(first, "confirm_finish", %{})

      assert is_nil(Repo.get!(GameSession, session.id).current_question_closed_at)
      assert Repo.get!(GameSession, session.id).status == :in_progress

      refute has_element?(second, "#access-lost-notice")
      refute has_element?(second, "#close-question[disabled]")
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

      {:ok, _expired} = session |> overdue_host_absence() |> Games.expire_game_session()

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

      assert html =~ "Partida finalizada"
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

      {:ok, first, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")
      {:ok, _second, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      render_click(first, "start", %{})
      render_click(first, "confirm_cancel", %{})

      assert Repo.get!(GameSession, session.id).status == :waiting
    end

    test "um evento de transferência forjado não tira o controle de quem o tem", %{
      conn: conn,
      session: session
    } do
      session |> participant_fixture() |> connect_participant()

      {:ok, lv, _html} = live(conn, ~p"/game-sessions/#{session.join_code}/host")

      # O evento diz que outra conexão assumiu; a linha diz que esta aba ainda
      # tem a sala. Só a linha decide — dois claims em sequência podem chegar em
      # qualquer ordem, e acreditar na última mensagem fazia a vencedora concluir
      # que tinha perdido.
      send(lv.pid, {:host_access_transferred, Ecto.UUID.generate()})

      refute has_element?(lv, "#access-lost-notice")

      render_click(lv, "start", %{})

      assert Repo.get!(GameSession, session.id).status == :in_progress
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

  # Uma partida de três perguntas já congeladas, parada antes do primeiro
  # avanço: o estado de onde todos os comandos da execução partem.
  defp running_room(%{user: user, scope: scope}) do
    quiz = quiz_fixture(scope, %{title: "Geografia"})
    for _ <- 1..3, do: question_fixture(scope, quiz)

    session = game_session_fixture(%{host: user, quiz: quiz, status: :in_progress})
    questions = snapshot_fixture(session, count: 3)

    :ok = Games.subscribe(session.id)

    %{quiz: quiz, session: session, questions: questions}
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

  defp play_to(scope, %GameSession{} = session, position) do
    Enum.reduce(1..position//1, session, fn target, current ->
      expected = if target == 1, do: nil, else: target - 1
      {:ok, advanced} = Games.advance_question(scope, current, expected)

      advanced
    end)
  end

  # Respostas gravadas direto pelo fixture: o que este teste descreve é a
  # distribuição de uma pergunta encerrada, não o caminho da resposta, e passar
  # pelo contexto encerraria a pergunta sozinho ao completar a sala (AD-42).
  defp answer_many(session, option, count) do
    for index <- 1..count//1 do
      session
      |> participant_fixture(%{nickname: "P#{option.position}-#{index}"})
      |> answer_fixture(option)
    end
  end

  defp answers_counter(lv) do
    lv
    |> element("#answers-count")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
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
