defmodule LiveQuizWeb.GameSessionLive.JoinTest do
  use LiveQuizWeb.ConnCase, async: true

  import ExUnit.CaptureLog
  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import Phoenix.LiveViewTest

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Repo
  alias LiveQuizWeb.ParticipantAuth

  @cookie ParticipantAuth.cookie_name()

  setup do
    %{session: game_session_fixture(%{quiz_title: "Quiz de História"})}
  end

  defp fill(lv, params), do: form(lv, "#join-form", join: params)

  defp validate(lv, params), do: lv |> fill(params) |> render_change()

  defp join(lv, params), do: lv |> fill(params) |> render_submit()

  # Faz o que o navegador faz quando a LiveView liga o `phx-trigger-action`:
  # posta o formulário para o controller, que grava o cookie e redireciona.
  defp complete_join(lv, conn, params) do
    form = fill(lv, params)
    render_submit(form)
    follow_trigger_action(form, conn)
  end

  # A configuração de teste silencia tudo abaixo de `:warning`, e o registro das
  # tentativas é `:info` — o mesmo nível que a produção grava.
  defp with_info_logs(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    capture_log(fun)
  end

  defp tokens_of(conn) do
    case conn.resp_cookies[@cookie] do
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

  describe "as três formas de chegar" do
    test "sem código, a tela pede código e apelido", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/join")

      assert html =~ "Entrar em uma sala"
      assert has_element?(lv, "#join-form")
      assert has_element?(lv, "#join-form input#join_code")
      assert has_element?(lv, "#join-form input#join_nickname")
      refute has_element?(lv, "#session-preview")
    end

    test "com ?code=, o campo de código já vem preenchido", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      assert lv |> element("#join_code") |> render() =~ session.join_code
      assert has_element?(lv, "#session-preview")
    end

    test "o código do link é normalizado", %{conn: conn, session: session} do
      code = String.downcase(session.join_code)

      {:ok, lv, _html} = live(conn, ~p"/join?code=#{code}")

      assert lv |> element("#join_code") |> render() =~ session.join_code
      assert has_element?(lv, "#preview-quiz-title")
    end

    test "a tela é pública e não redireciona para o login", %{conn: conn} do
      assert {:ok, _lv, html} = live(conn, ~p"/join")
      assert html =~ "Não é preciso ter conta para participar"
    end
  end

  describe "preview da sala" do
    test "mostra título e disponibilidade", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      assert lv |> element("#preview-quiz-title") |> render() =~ "Quiz de História"
      assert lv |> element("#preview-availability") |> render() =~ "Sala aberta para entrada"
    end

    test "não mostra a lista nem a quantidade de participantes", %{conn: conn, session: session} do
      participant_fixture(session, %{nickname: "Ana"})
      participant_fixture(session, %{nickname: "Bruno"})

      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")
      html = render(lv)

      refute html =~ "Ana"
      refute html =~ "Bruno"
      refute html =~ "2 de 25"
      refute html =~ "Inscritos"
      refute html =~ "Conectados"
    end

    test "sala lotada aparece como indisponível", %{conn: conn} do
      session = full_session()

      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      assert lv |> element("#preview-availability") |> render() =~ "não está aceitando entradas"
    end

    test "sala já iniciada aparece como indisponível", %{conn: conn} do
      session = game_session_fixture(%{status: :in_progress})

      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      assert lv |> element("#preview-availability") |> render() =~ "não está aceitando entradas"
    end

    test "código inexistente não tem preview", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/join?code=ZZZZZZ")

      refute has_element?(lv, "#session-preview")
    end

    test "o preview aparece assim que o código válido é digitado", %{
      conn: conn,
      session: session
    } do
      {:ok, lv, _html} = live(conn, ~p"/join")

      refute has_element?(lv, "#session-preview")

      validate(lv, %{code: session.join_code, nickname: ""})

      assert lv |> element("#preview-quiz-title") |> render() =~ "Quiz de História"
    end
  end

  describe "validação do apelido enquanto se digita" do
    test "um caractere é curto demais", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      assert validate(lv, %{code: session.join_code, nickname: "A"}) =~
               "deve ter pelo menos 2 caracteres"
    end

    test "dois caracteres já valem", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      html = validate(lv, %{code: session.join_code, nickname: "Al"})

      refute html =~ "deve ter pelo menos"
      refute html =~ "deve ter no máximo"
    end

    test "vinte caracteres ainda valem", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      html = validate(lv, %{code: session.join_code, nickname: String.duplicate("a", 20)})

      refute html =~ "deve ter no máximo"
    end

    test "vinte e um caracteres são longos demais", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      assert validate(lv, %{code: session.join_code, nickname: String.duplicate("a", 21)}) =~
               "deve ter no máximo 20 caracteres"
    end

    test "emoji não é aceito", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      assert validate(lv, %{code: session.join_code, nickname: "Ana 🎉"}) =~
               "use apenas letras, números, espaços, hífen e sublinhado"
    end

    test "só espaços conta como vazio", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      assert validate(lv, %{code: session.join_code, nickname: "   "}) =~
               "não pode ficar em branco"
    end

    test "a unicidade não é prometida durante a digitação", %{conn: conn, session: session} do
      participant_fixture(session, %{nickname: "Ana"})

      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      refute validate(lv, %{code: session.join_code, nickname: "Ana"}) =~ "já está em uso"
    end

    test "avisa que o apelido não poderá ser trocado", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      assert lv |> element("#nickname-hint") |> render() =~ "não pode ser trocado"
    end
  end

  describe "validação do código" do
    test "caractere fora do alfabeto é recusado sem consultar o banco", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/join")

      html = join(lv, %{code: "K7P4Q0", nickname: "Ana"})

      assert html =~ "código inválido"
      refute html =~ "Sala não encontrada"
      refute has_element?(lv, "#session-preview")
      assert Repo.aggregate(Participant, :count) == 0
    end

    test "código com o tamanho errado é recusado pelo formato", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/join")

      assert join(lv, %{code: "K7P4", nickname: "Ana"}) =~ "código inválido"
      assert Repo.aggregate(Participant, :count) == 0
    end

    test "código vazio pede o código", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/join")

      assert join(lv, %{code: "", nickname: "Ana"}) =~ "informe o código da sala"
    end

    test "código inexistente, mas bem formado, diz sala não encontrada", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/join")

      assert join(lv, %{code: "ZZZZZZ", nickname: "Ana"}) =~ "Sala não encontrada"
    end

    test "a tentativa em código inexistente vai para o log", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/join")

      log = with_info_logs(fn -> join(lv, %{code: "ZZZZZZ", nickname: "Ana"}) end)

      assert log =~ "join attempt on unknown room code"
      assert log =~ "ZZZZZZ"
    end

    test "a tentativa em sala existente não polui o log", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      log = with_info_logs(fn -> join(lv, %{code: session.join_code, nickname: "Ana"}) end)

      refute log =~ "join attempt on unknown room code"
    end
  end

  describe "entrada de visitante" do
    test "entra na sala, grava a credencial e vai para o lobby", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      conn = complete_join(lv, conn, %{code: session.join_code, nickname: "Ana"})

      assert redirected_to(conn) == "/game-sessions/#{session.join_code}"

      participant = Repo.get_by!(Participant, game_session_id: session.id, nickname: "Ana")
      assert is_nil(participant.user_id)

      tokens = tokens_of(conn)
      assert {:ok, ^participant} = Games.get_participant_by_token(tokens[session.join_code])
    end

    test "o código digitado em minúsculas encontra a sala", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/join")

      conn =
        complete_join(lv, conn, %{code: String.downcase(session.join_code), nickname: "Ana"})

      assert redirected_to(conn) == "/game-sessions/#{session.join_code}"
      assert Repo.get_by!(Participant, game_session_id: session.id).nickname == "Ana"
    end

    test "o token não aparece na URL do lobby", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      conn = complete_join(lv, conn, %{code: session.join_code, nickname: "Ana"})
      token = tokens_of(conn)[session.join_code]

      refute redirected_to(conn) =~ token
    end
  end

  describe "entrada de quem tem conta" do
    setup %{conn: conn} do
      user = user_fixture(%{name: "Ana Souza"})

      %{conn: log_in_user(conn, user), user: user}
    end

    test "o apelido vem sugerido com o nome da conta", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      assert lv |> element("#join_nickname") |> render() =~ "Ana Souza"
    end

    test "entra com o user_id preenchido", %{conn: conn, session: session, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      conn = complete_join(lv, conn, %{code: session.join_code, nickname: "Ana"})

      assert redirected_to(conn) == "/game-sessions/#{session.join_code}"
      assert Repo.get_by!(Participant, game_session_id: session.id).user_id == user.id
    end

    test "trocar o apelido não altera o cadastro", %{conn: conn, session: session, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      complete_join(lv, conn, %{code: session.join_code, nickname: "Aninha"})

      assert Repo.get_by!(Participant, game_session_id: session.id).nickname == "Aninha"
      assert Repo.reload!(user).name == "Ana Souza"
    end
  end

  describe "conta sem nome aproveitável" do
    test "o apelido vem vazio", %{conn: conn, session: session} do
      conn = log_in_user(conn, user_fixture(%{name: "🎉🎉"}))

      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      refute lv |> element("#join_nickname") |> render() =~ "🎉"
    end
  end

  describe "as cinco recusas" do
    test "sala não encontrada", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/join")

      assert join(lv, %{code: "ZZZZZZ", nickname: "Ana"}) =~ "Sala não encontrada."
    end

    test "a partida já começou", %{conn: conn} do
      session = game_session_fixture(%{status: :in_progress})

      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      assert join(lv, %{code: session.join_code, nickname: "Ana"}) =~ "Esta partida já começou."
    end

    test "sala lotada, e nenhuma fila de espera", %{conn: conn} do
      session = full_session()

      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      html = join(lv, %{code: session.join_code, nickname: "Ana"})

      assert html =~ "Sala lotada."
      refute html =~ "fila de espera"
      refute html =~ "Avise-me"
    end

    test "apelido já em uso, no próprio campo", %{conn: conn, session: session} do
      participant_fixture(session, %{nickname: "Ana"})

      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      html = join(lv, %{code: session.join_code, nickname: "ana"})

      assert html =~ "apelido já está em uso nesta sala"
      assert has_element?(lv, "#join-form")
      refute has_element?(lv, "#join-error")
      assert Repo.aggregate(Participant, :count) == 1
    end

    test "visitante já preso a outra sala", %{conn: conn} do
      other = game_session_fixture()

      {:ok, _participant, token} =
        Games.join_game_session(nil, other.join_code, %{"nickname" => "Ana"})

      session = game_session_fixture()
      conn = put_participant_token(conn, other.join_code, token)

      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      assert join(lv, %{code: session.join_code, nickname: "Ana"}) =~
               "Você já está em outra sala. Saia dela para entrar aqui."
    end

    test "pessoa com conta já presa a outra sala", %{conn: conn} do
      user = user_fixture()
      other = game_session_fixture()

      {:ok, _participant, _token} =
        Games.join_game_session(
          Scope.for_user(user),
          other.join_code,
          %{"nickname" => "Ana"}
        )

      session = game_session_fixture()
      conn = log_in_user(conn, user)

      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      assert join(lv, %{code: session.join_code, nickname: "Ana"}) =~
               "Você já está em outra sala"
    end
  end

  describe "credenciais que o navegador já tem" do
    test "quem já participa desta sala vai direto ao lobby", %{conn: conn, session: session} do
      {:ok, _participant, token} =
        Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"})

      conn = put_participant_token(conn, session.join_code, token)

      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/join?code=#{session.join_code}")
      assert to == "/game-sessions/#{session.join_code}"
      assert Repo.aggregate(Participant, :count) == 1
    end

    test "credencial de outra sala não desvia da tela", %{conn: conn, session: session} do
      other = game_session_fixture()

      {:ok, _participant, token} =
        Games.join_game_session(nil, other.join_code, %{"nickname" => "Ana"})

      conn = put_participant_token(conn, other.join_code, token)

      assert {:ok, _lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")
    end

    test "credencial desconhecida não derruba a tela", %{conn: conn, session: session} do
      conn = put_participant_token(conn, session.join_code, "credencial-que-nao-vale-nada")

      assert {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")
      assert has_element?(lv, "#join-form")
    end

    test "quem saiu é levado ao lobby, onde o retorno acontece", %{
      conn: conn,
      session: session
    } do
      {:ok, participant, token} =
        Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"})

      {:ok, _participant} = Games.leave_game_session(participant)

      conn = put_participant_token(conn, session.join_code, token)

      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/join?code=#{session.join_code}")
      assert to == "/game-sessions/#{session.join_code}"
      assert Repo.aggregate(Participant, :count) == 1
    end
  end

  describe "acessibilidade" do
    test "os campos têm rótulo associado", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      assert has_element?(lv, "label[for=join_code]")
      assert has_element?(lv, "label[for=join_nickname]")
      assert lv |> element("label[for=join_code]") |> render() =~ "Código da sala"
      assert lv |> element("label[for=join_nickname]") |> render() =~ "Seu apelido"
    end

    test "o aviso sobre o apelido fixo está ligado ao campo", %{conn: conn, session: session} do
      {:ok, lv, _html} = live(conn, ~p"/join?code=#{session.join_code}")

      assert has_element?(lv, "input#join_nickname[aria-describedby=nickname-hint]")
      assert has_element?(lv, "#nickname-hint")
    end

    test "a recusa da sala é anunciada como alerta", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/join")

      join(lv, %{code: "ZZZZZZ", nickname: "Ana"})

      assert has_element?(lv, "#join-error[role=alert]")
    end
  end

  defp full_session do
    session = game_session_fixture()

    for _seat <- 1..Games.max_participants(), do: participant_fixture(session)

    session
  end
end
