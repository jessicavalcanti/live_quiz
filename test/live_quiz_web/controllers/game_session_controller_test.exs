defmodule LiveQuizWeb.GameSessionControllerTest do
  use LiveQuizWeb.ConnCase, async: true

  import LiveQuiz.GamesFixtures
  import LiveQuiz.QuizzesFixtures

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games
  alias LiveQuizWeb.ParticipantAuth

  @cookie ParticipantAuth.cookie_name()

  describe "POST /game-sessions (abrir sala)" do
    setup :register_and_log_in_user

    test "abre a sala e leva para o lobby do host", %{conn: conn, user: user} do
      quiz = quiz_with_question(user)

      conn = post(conn, ~p"/game-sessions", %{"quiz_id" => quiz.id})

      session = Games.get_active_session_for_host(Scope.for_user(user))

      assert redirected_to(conn) == ~p"/game-sessions/#{session.join_code}/host"
    end

    test "sem pergunta, recusa com a mensagem do contexto", %{conn: conn, user: user} do
      quiz = quiz_fixture(Scope.for_user(user))

      conn = post(conn, ~p"/game-sessions", %{"quiz_id" => quiz.id})

      assert redirected_to(conn) == ~p"/quizzes"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Adicione ao menos uma pergunta"
    end
  end

  describe "POST /game-sessions/join" do
    test "grava a credencial e leva ao lobby do participante", %{conn: conn} do
      session = game_session_fixture()

      conn =
        post(conn, ~p"/game-sessions/join", %{
          "code" => session.join_code,
          "token" => "token-do-participante"
        })

      assert redirected_to(conn) == "/game-sessions/#{session.join_code}"
      assert %{value: value} = conn.resp_cookies[@cookie]
      assert is_binary(value)
    end

    test "o cookie é assinado, http_only, same_site Lax e dura 30 dias", %{conn: conn} do
      conn =
        post(conn, ~p"/game-sessions/join", %{"code" => "K7P4Q2", "token" => "token-1"})

      assert %{http_only: true, same_site: "Lax", max_age: 2_592_000} = conn.resp_cookies[@cookie]
      # Assinado: o token não aparece em claro no valor entregue ao navegador.
      refute conn.resp_cookies[@cookie].value =~ "token-1"
    end

    test "normaliza o código antes de gravar e de redirecionar", %{conn: conn} do
      conn = post(conn, ~p"/game-sessions/join", %{"code" => " k7p4q2 ", "token" => "token-1"})

      assert redirected_to(conn) == "/game-sessions/K7P4Q2"

      assert ParticipantAuth.read_tokens(recycled(conn)) == %{"K7P4Q2" => "token-1"}
    end

    test "o token não viaja na URL do lobby", %{conn: conn} do
      conn = post(conn, ~p"/game-sessions/join", %{"code" => "K7P4Q2", "token" => "segredo"})

      refute redirected_to(conn) =~ "segredo"
    end

    test "preserva as credenciais das outras salas", %{conn: conn} do
      conn =
        conn
        |> put_participant_token("J9M3T5", "token-antigo")
        |> post(~p"/game-sessions/join", %{"code" => "K7P4Q2", "token" => "token-novo"})

      assert ParticipantAuth.read_tokens(recycled(conn)) == %{
               "J9M3T5" => "token-antigo",
               "K7P4Q2" => "token-novo"
             }
    end

    test "sem token, volta para a tela de entrada com o aviso", %{conn: conn} do
      conn = post(conn, ~p"/game-sessions/join", %{"code" => "K7P4Q2"})

      assert redirected_to(conn) == ~p"/join"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Não foi possível entrar"
      refute Map.has_key?(conn.resp_cookies, @cookie)
    end
  end

  describe "DELETE /game-sessions/:code/leave" do
    test "esquece só a credencial daquela sala", %{conn: conn} do
      conn =
        conn
        |> put_participant_token("J9M3T5", "token-1")
        |> then(&post(&1, ~p"/game-sessions/join", %{"code" => "K7P4Q2", "token" => "token-2"}))
        |> recycled()
        |> delete(~p"/game-sessions/K7P4Q2/leave")

      assert redirected_to(conn) == ~p"/join"
      assert ParticipantAuth.read_tokens(recycled(conn)) == %{"J9M3T5" => "token-1"}
    end

    test "esquecer a última credencial apaga o cookie", %{conn: conn} do
      conn =
        conn
        |> put_participant_token("K7P4Q2", "token-1")
        |> delete(~p"/game-sessions/K7P4Q2/leave")

      assert %{max_age: 0} = conn.resp_cookies[@cookie]
    end

    test "esquecer uma sala desconhecida não derruba a tela", %{conn: conn} do
      conn = delete(conn, ~p"/game-sessions/K7P4Q2/leave")

      assert redirected_to(conn) == ~p"/join"
    end
  end

  # Devolve a conexão como o navegador a apresentaria na requisição seguinte:
  # o cookie escrito na resposta volta como cookie de requisição.
  defp recycled(conn) do
    case conn.resp_cookies[@cookie] do
      %{value: value} ->
        conn
        |> recycle()
        |> Map.replace!(:secret_key_base, LiveQuizWeb.Endpoint.config(:secret_key_base))
        |> Plug.Test.put_req_cookie(@cookie, value)

      _absent ->
        conn
    end
  end

  defp quiz_with_question(user) do
    scope = Scope.for_user(user)
    quiz = quiz_fixture(scope)
    _question = question_fixture(scope, quiz)

    quiz
  end
end
