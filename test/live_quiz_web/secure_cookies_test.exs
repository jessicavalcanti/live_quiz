defmodule LiveQuizWeb.SecureCookiesTest do
  @moduledoc """
  Cada cookie desta aplicação carrega uma credencial, e os três são marcados
  `secure` onde ela é servida por https.

  `async: false` porque a chave é configuração global: um caso que a liga tem de
  ser o único rodando, e o ExUnit roda os síncronos depois de todos os
  assíncronos, um de cada vez.
  """

  use LiveQuizWeb.ConnCase, async: false

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures

  alias LiveQuizWeb.ParticipantAuth
  alias LiveQuizWeb.UserAuth

  setup %{conn: conn} do
    on_exit(fn -> Application.put_env(:live_quiz, :secure_cookies, false) end)

    conn =
      conn
      |> Map.replace!(:secret_key_base, LiveQuizWeb.Endpoint.config(:secret_key_base))
      |> Plug.Test.init_test_session(%{})

    %{conn: conn}
  end

  defp serving_https do
    Application.put_env(:live_quiz, :secure_cookies, true)
  end

  describe "a chave que decide" do
    test "está desligada por padrão, porque dev e teste falam http" do
      # Um cookie `secure` mandado por http é um cookie que o navegador nunca
      # devolve: ligá-la em todo lugar não endureceria nada, quebraria entrar
      # na aplicação localmente.
      refute LiveQuizWeb.secure_cookies?()
    end

    test "produção a liga" do
      # `force_ssl` já mantém o navegador em https, mas a flag é a única
      # proteção que não depende do resto estar certo.
      assert File.read!("config/prod.exs") =~ "config :live_quiz, :secure_cookies, true"
    end
  end

  describe "o cookie de credenciais de participação" do
    test "não é secure enquanto a aplicação fala http" do
      refute Keyword.fetch!(ParticipantAuth.cookie_options(), :secure)
    end

    test "é secure quando ela fala https, sem perder o que já tinha" do
      serving_https()

      options = ParticipantAuth.cookie_options()

      assert Keyword.fetch!(options, :secure)
      assert Keyword.fetch!(options, :http_only)
      assert Keyword.fetch!(options, :sign)
      assert Keyword.fetch!(options, :same_site) == "Lax"
    end

    test "a flag chega ao cookie que a resposta escreve", %{conn: conn} do
      serving_https()
      session = game_session_fixture()

      conn =
        ParticipantAuth.put_token(conn, session.join_code, "um-token")

      assert %{secure: true, http_only: true} = conn.resp_cookies["lq_participant"]
    end
  end

  describe "o cookie de lembrar-me da conta" do
    test "a flag chega ao cookie quando a pessoa pede para ser lembrada", %{conn: conn} do
      serving_https()
      user = user_fixture()

      conn =
        UserAuth.log_in_user(conn, user, %{"remember_me" => "true"})

      assert %{secure: true} = conn.resp_cookies["_live_quiz_web_user_remember_me"]
    end

    test "e não chega enquanto a aplicação fala http", %{conn: conn} do
      user = user_fixture()

      conn =
        UserAuth.log_in_user(conn, user, %{"remember_me" => "true"})

      refute conn.resp_cookies["_live_quiz_web_user_remember_me"][:secure]
    end
  end

  describe "o cookie de sessão" do
    test "é decidido quando o endpoint compila, e prod compila com a chave ligada" do
      # `Plug.Session` lê as opções na compilação do endpoint, então este é o
      # único dos três que não dá para virar em tempo de execução — o que se
      # verifica é que o endpoint pergunta, e que produção responde sim.
      assert File.read!("lib/live_quiz_web/endpoint.ex") =~
               "secure: Application.compile_env(:live_quiz, :secure_cookies, false)"
    end
  end
end
