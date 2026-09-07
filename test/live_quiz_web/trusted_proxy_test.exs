defmodule LiveQuizWeb.TrustedProxyTest do
  @moduledoc """
  De quem é a requisição, quando há um proxy no caminho.

  O modo de falha que importa não é "o abuso passa": é a sala de trinta pessoas
  que se tranca sozinha porque as trinta contam como uma. Por isso a topologia é
  declarada e nunca adivinhada.
  """

  use LiveQuizWeb.ConnCase, async: false

  alias LiveQuizWeb.RateLimit

  setup do
    on_exit(fn -> Application.delete_env(:live_quiz, RateLimit) end)

    :ok
  end

  defp behind(hops) do
    Application.put_env(:live_quiz, RateLimit, trusted_proxy_hops: hops)
  end

  defp request(peer, forwarded) do
    conn = %{Phoenix.ConnTest.build_conn() | remote_ip: peer}

    Enum.reduce(forwarded, conn, &Plug.Conn.put_req_header(&2, "x-forwarded-for", &1))
  end

  describe "sem proxy nenhum" do
    test "conta o par do socket, que ninguém consegue forjar" do
      assert RateLimit.trusted_proxy_hops() == 0

      # O cabeçalho está ali e é ignorado: quem manda a requisição escreve o
      # valor, e um limitador com chave num valor do atacante não é limitador.
      assert RateLimit.origin(request({198, 51, 100, 7}, ["203.0.113.9"])) ==
               {198, 51, 100, 7}
    end
  end

  describe "com um proxy declarado" do
    setup do
      behind(1)
    end

    test "conta o endereço que o proxy confiável observou" do
      assert RateLimit.origin(request({10, 0, 0, 1}, ["203.0.113.9"])) == {203, 0, 113, 9}
    end

    test "duas pessoas atrás do mesmo proxy têm orçamentos separados" do
      # É este o ponto. Sem isto, a sala inteira divide um balde.
      primeira = RateLimit.origin(request({10, 0, 0, 1}, ["203.0.113.9"]))
      segunda = RateLimit.origin(request({10, 0, 0, 1}, ["203.0.113.40"]))

      refute primeira == segunda
    end

    test "o que o cliente escreveu antes não vale nada" do
      # O cliente mandou um endereço; o proxy anexou o que viu de verdade. O
      # que conta é o do proxy, que está no fim.
      assert RateLimit.origin(request({10, 0, 0, 1}, ["1.2.3.4, 203.0.113.9"])) ==
               {203, 0, 113, 9}
    end

    test "aceita a lista partida em cabeçalhos repetidos" do
      assert RateLimit.origin(request({10, 0, 0, 1}, ["1.2.3.4", "203.0.113.9"])) ==
               {203, 0, 113, 9}
    end

    test "um v6 continua contado pelo /64" do
      assert RateLimit.origin(request({10, 0, 0, 1}, ["2001:db8:0:1:0:0:0:5"])) ==
               {0x2001, 0xDB8, 0, 1}
    end
  end

  describe "com dois proxies declarados" do
    setup do
      behind(2)
    end

    test "conta o segundo a partir do fim" do
      forwarded = ["1.2.3.4, 203.0.113.9, 192.0.2.77"]

      assert RateLimit.origin(request({10, 0, 0, 1}, forwarded)) == {203, 0, 113, 9}
    end
  end

  describe "quando o cabeçalho não é o que foi declarado" do
    setup do
      behind(2)
    end

    test "com saltos de menos, volta para o par e avisa" do
      handler = attach()

      # Um balde só é a resposta segura — nunca o orçamento de outra pessoa —, e
      # dizer isso alto é o que transforma erro de configuração em algo
      # encontrável.
      assert RateLimit.origin(request({10, 0, 0, 1}, ["203.0.113.9"])) == {10, 0, 0, 1}
      assert_receive {:untrusted, %{reason: :too_few_hops}}

      :telemetry.detach(handler)
    end

    test "sem cabeçalho nenhum, volta para o par e avisa" do
      handler = attach()

      assert RateLimit.origin(request({10, 0, 0, 1}, [])) == {10, 0, 0, 1}
      assert_receive {:untrusted, %{reason: :too_few_hops}}

      :telemetry.detach(handler)
    end

    test "com lixo no lugar de um endereço, volta para o par e avisa" do
      handler = attach()

      assert RateLimit.origin(request({10, 0, 0, 1}, ["nao-e-um-ip, 192.0.2.77"])) ==
               {10, 0, 0, 1}

      assert_receive {:untrusted, %{reason: :unparsable}}

      :telemetry.detach(handler)
    end
  end

  describe "a configuração de produção" do
    test "não tem padrão, porque o padrão silencioso é o defeito" do
      runtime = File.read!("config/runtime.exs")

      assert runtime =~ "TRUSTED_PROXY_HOPS"
      assert runtime =~ "environment variable TRUSTED_PROXY_HOPS is missing"
    end
  end

  defp attach do
    handler = "untrusted-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      handler,
      [:live_quiz, :rate_limit, :untrusted_origin],
      fn _event, _measurements, metadata, _config -> send(test, {:untrusted, metadata}) end,
      nil
    )

    handler
  end
end
