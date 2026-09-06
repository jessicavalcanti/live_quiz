defmodule LiveQuizWeb.ParticipantAuthTest do
  use LiveQuizWeb.ConnCase, async: true

  alias LiveQuizWeb.ParticipantAuth

  @cookie ParticipantAuth.cookie_name()
  @session_key ParticipantAuth.session_key()

  setup %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Map.replace!(:secret_key_base, LiveQuizWeb.Endpoint.config(:secret_key_base))

    %{conn: conn}
  end

  # Moves a written cookie back to the request side, which is what the next
  # request of the same browser would present.
  defp recycle_cookie(conn) do
    %{value: signed} = conn.resp_cookies[@cookie]

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Test.put_req_cookie(@cookie, signed)
  end

  defp sign(conn, term) do
    %{value: signed} =
      Plug.Conn.put_resp_cookie(conn, @cookie, term, sign: true).resp_cookies[@cookie]

    Plug.Test.put_req_cookie(conn, @cookie, signed)
  end

  describe "read_tokens/1 de uma conexão" do
    test "sem cookie devolve mapa vazio", %{conn: conn} do
      assert ParticipantAuth.read_tokens(conn) == %{}
    end

    test "com cookie vazio devolve mapa vazio", %{conn: conn} do
      conn = Plug.Test.put_req_cookie(conn, @cookie, "")

      assert ParticipantAuth.read_tokens(conn) == %{}
    end

    test "com cookie corrompido devolve mapa vazio", %{conn: conn} do
      conn = Plug.Test.put_req_cookie(conn, @cookie, "isto-nao-e-um-cookie-assinado")

      assert ParticipantAuth.read_tokens(conn) == %{}
    end

    test "com assinatura de outro segredo devolve mapa vazio", %{conn: conn} do
      other = %{conn | secret_key_base: String.duplicate("z", 64)}

      %{value: signed} =
        Plug.Conn.put_resp_cookie(other, @cookie, [{"K7P4Q2", "t"}], sign: true).resp_cookies[
          @cookie
        ]

      conn = Plug.Test.put_req_cookie(conn, @cookie, signed)

      assert ParticipantAuth.read_tokens(conn) == %{}
    end

    test "com conteúdo que não é uma lista de pares devolve mapa vazio", %{conn: conn} do
      assert ParticipantAuth.read_tokens(sign(conn, %{"K7P4Q2" => "t"})) == %{}
      assert ParticipantAuth.read_tokens(sign(conn, "K7P4Q2")) == %{}
      assert ParticipantAuth.read_tokens(sign(conn, [1, 2, 3])) == %{}
    end

    test "descarta as entradas malformadas de uma lista", %{conn: conn} do
      conn = sign(conn, [{"K7P4Q2", "bom"}, {:atomo, "ruim"}, {"OUTRA", 42}])

      assert ParticipantAuth.read_tokens(conn) == %{"K7P4Q2" => "bom"}
    end

    test "devolve o que put_token gravou", %{conn: conn} do
      conn = conn |> ParticipantAuth.put_token("K7P4Q2", "token-1") |> recycle_cookie()

      assert ParticipantAuth.read_tokens(conn) == %{"K7P4Q2" => "token-1"}
    end
  end

  describe "read_tokens/1 de uma sessão de LiveView" do
    test "sem a chave devolve mapa vazio" do
      assert ParticipantAuth.read_tokens(%{}) == %{}
      assert ParticipantAuth.read_tokens(%{"user_token" => "x"}) == %{}
    end

    test "com lixo na chave devolve mapa vazio" do
      assert ParticipantAuth.read_tokens(%{@session_key => "lixo"}) == %{}
      assert ParticipantAuth.read_tokens(%{@session_key => nil}) == %{}
    end

    test "devolve o mapa das entradas válidas" do
      session = %{@session_key => [{"K7P4Q2", "token-1"}, {"J9M3T5", "token-2"}]}

      assert ParticipantAuth.read_tokens(session) == %{
               "K7P4Q2" => "token-1",
               "J9M3T5" => "token-2"
             }
    end
  end

  describe "put_token/3" do
    test "normaliza o código antes de guardar", %{conn: conn} do
      conn = conn |> ParticipantAuth.put_token(" k7p4q2 ", "token-1") |> recycle_cookie()

      assert ParticipantAuth.read_tokens(conn) == %{"K7P4Q2" => "token-1"}
    end

    test "grava o cookie com http_only, same_site e validade de 30 dias", %{conn: conn} do
      conn = ParticipantAuth.put_token(conn, "K7P4Q2", "token-1")

      assert %{http_only: true, same_site: "Lax", max_age: max_age} = conn.resp_cookies[@cookie]
      assert max_age == 60 * 60 * 24 * 30
      assert max_age == ParticipantAuth.max_age()
    end

    test "guarda várias salas ao mesmo tempo", %{conn: conn} do
      conn =
        conn
        |> ParticipantAuth.put_token("K7P4Q2", "token-1")
        |> recycle_cookie()
        |> ParticipantAuth.put_token("J9M3T5", "token-2")
        |> recycle_cookie()

      assert ParticipantAuth.read_tokens(conn) == %{
               "K7P4Q2" => "token-1",
               "J9M3T5" => "token-2"
             }
    end

    test "entrar de novo na mesma sala substitui o token, sem duplicar", %{conn: conn} do
      conn =
        conn
        |> ParticipantAuth.put_token("K7P4Q2", "token-1")
        |> recycle_cookie()
        |> ParticipantAuth.put_token("K7P4Q2", "token-2")
        |> recycle_cookie()

      assert ParticipantAuth.read_tokens(conn) == %{"K7P4Q2" => "token-2"}
    end

    test "mantém no máximo 20 entradas, descartando as mais antigas", %{conn: conn} do
      codes = for index <- 1..25, do: "SALA#{String.pad_leading("#{index}", 2, "0")}"

      conn =
        Enum.reduce(codes, conn, fn code, conn ->
          conn |> ParticipantAuth.put_token(code, "token-#{code}") |> recycle_cookie()
        end)

      tokens = ParticipantAuth.read_tokens(conn)
      {dropped, kept} = Enum.split(codes, 5)

      assert map_size(tokens) == ParticipantAuth.max_entries()
      assert map_size(tokens) == 20
      assert Enum.all?(kept, &Map.has_key?(tokens, &1))
      refute Enum.any?(dropped, &Map.has_key?(tokens, &1))
    end

    test "reentrar em uma sala antiga a protege do descarte", %{conn: conn} do
      conn =
        Enum.reduce(1..20, conn, fn index, conn ->
          conn |> ParticipantAuth.put_token("SALA#{index}", "token-#{index}") |> recycle_cookie()
        end)

      conn =
        conn
        |> ParticipantAuth.put_token("SALA1", "token-novo")
        |> recycle_cookie()
        |> ParticipantAuth.put_token("NOVA", "token-nova")
        |> recycle_cookie()

      tokens = ParticipantAuth.read_tokens(conn)

      assert tokens["SALA1"] == "token-novo"
      assert tokens["NOVA"] == "token-nova"
      refute Map.has_key?(tokens, "SALA2")
    end
  end

  describe "drop_token/2" do
    test "remove só a sala indicada", %{conn: conn} do
      conn =
        conn
        |> ParticipantAuth.put_token("K7P4Q2", "token-1")
        |> recycle_cookie()
        |> ParticipantAuth.put_token("J9M3T5", "token-2")
        |> recycle_cookie()
        |> ParticipantAuth.drop_token("K7P4Q2")
        |> recycle_cookie()

      assert ParticipantAuth.read_tokens(conn) == %{"J9M3T5" => "token-2"}
    end

    test "normaliza o código antes de remover", %{conn: conn} do
      conn =
        conn
        |> ParticipantAuth.put_token("K7P4Q2", "token-1")
        |> recycle_cookie()
        |> ParticipantAuth.drop_token(" k7p4q2 ")

      assert conn.assigns.participant_tokens == %{}
    end

    test "apagar a última entrada apaga o cookie", %{conn: conn} do
      conn =
        conn
        |> ParticipantAuth.put_token("K7P4Q2", "token-1")
        |> recycle_cookie()
        |> ParticipantAuth.drop_token("K7P4Q2")

      assert %{max_age: 0} = conn.resp_cookies[@cookie]
      assert conn.assigns.participant_tokens == %{}
    end

    test "remover uma sala que não está guardada não muda nada", %{conn: conn} do
      conn =
        conn
        |> ParticipantAuth.put_token("K7P4Q2", "token-1")
        |> recycle_cookie()
        |> ParticipantAuth.drop_token("J9M3T5")
        |> recycle_cookie()

      assert ParticipantAuth.read_tokens(conn) == %{"K7P4Q2" => "token-1"}
    end
  end

  describe "fetch_participant_tokens/2" do
    test "espelha as credenciais no assign e na sessão", %{conn: conn} do
      conn =
        conn
        |> ParticipantAuth.put_token("K7P4Q2", "token-1")
        |> recycle_cookie()
        |> ParticipantAuth.fetch_participant_tokens([])

      assert conn.assigns.participant_tokens == %{"K7P4Q2" => "token-1"}
      assert Plug.Conn.get_session(conn, @session_key) == [{"K7P4Q2", "token-1"}]
    end

    test "sem cookie deixa o assign vazio", %{conn: conn} do
      conn = ParticipantAuth.fetch_participant_tokens(conn, [])

      assert conn.assigns.participant_tokens == %{}
    end
  end

  describe "on_mount :mount_participant_tokens" do
    test "assina as credenciais da sessão sem interromper" do
      socket = %Phoenix.LiveView.Socket{}
      session = %{@session_key => [{"K7P4Q2", "token-1"}]}

      assert {:cont, socket} =
               ParticipantAuth.on_mount(:mount_participant_tokens, %{}, session, socket)

      assert socket.assigns.participant_tokens == %{"K7P4Q2" => "token-1"}
    end

    test "sem credencial alguma assina um mapa vazio" do
      socket = %Phoenix.LiveView.Socket{}

      assert {:cont, socket} =
               ParticipantAuth.on_mount(:mount_participant_tokens, %{}, %{}, socket)

      assert socket.assigns.participant_tokens == %{}
    end
  end
end
