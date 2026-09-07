defmodule LiveQuiz.Mail.CourierTest do
  @moduledoc """
  O carteiro: quem entrega, e por que não é quem pediu (R07).

  `async: false` porque o carteiro é um processo à parte e precisa da sandbox
  compartilhada — que é exatamente a razão de ele existir: entregar acontece
  fora da requisição que gravou a mensagem.
  """

  use LiveQuiz.DataCase, async: false

  import Swoosh.TestAssertions

  alias LiveQuiz.Mail
  alias LiveQuiz.Mail.Courier

  setup do
    # O carteiro é outro processo, e o adaptador de teste manda o e-mail para
    # quem enviou. Apontá-lo para este teste é o que deixa a entrega visível
    # daqui — e é justamente por acontecer noutro processo que ela existe.
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)

    :ok
  end

  test "entrega o que está gravado, em outro processo" do
    {:ok, _delivery} = Mail.record(intent())

    assert Courier.drain_now() == 1
    assert_email_sent()
    assert Mail.pending_count() == 0
  end

  test "um pedido de drenar não derruba o carteiro quando o provedor explode" do
    Application.put_env(:live_quiz, LiveQuiz.Mailer, adapter: __MODULE__.RaisingAdapter)

    on_exit(fn ->
      Application.put_env(:live_quiz, LiveQuiz.Mailer, adapter: Swoosh.Adapters.Test)
    end)

    {:ok, _delivery} = Mail.record(intent())
    courier = Process.whereis(Courier)

    assert Courier.drain_now() == 0

    # A mensagem continua devida e o processo continua de pé: o próximo tique
    # tenta de novo, que é a diferença entre um provedor com problema e uma
    # aplicação com problema.
    assert Process.whereis(Courier) == courier
    assert Mail.pending_count() == 1
  end

  test "um empurrão entrega sem que ninguém espere a resposta" do
    {:ok, _delivery} = Mail.record(intent())

    assert Courier.nudge() == :ok
    # Uma chamada é respondida depois do cast que chegou antes dela, então isto
    # é o empurrão ter terminado — e não um palpite sobre quando terminou.
    assert Courier.drain_now() == 0

    assert_email_sent()
    assert Mail.pending_count() == 0
  end

  test "o tique entrega sozinho quando está ligado" do
    {:ok, _delivery} = Mail.record(intent())

    ticking = start_supervised!({Courier, [enabled: true, name: :ticking_courier]})
    send(ticking, :tick)
    :sys.get_state(ticking)

    assert Mail.pending_count() == 0
  end

  test "e não entrega nada quando está desligado" do
    {:ok, _delivery} = Mail.record(intent())

    send(Process.whereis(Courier), :tick)
    :sys.get_state(Courier)

    assert Mail.pending_count() == 1
  end

  test "nada a fazer é zero, não um erro" do
    assert Courier.drain_now() == 0
  end

  test "não drena sozinho durante a suíte" do
    # O tique existe em produção; ligá-lo aqui faria uma mensagem sumir do meio
    # de outro teste.
    refute Courier.enabled?()
  end

  defp intent(overrides \\ []) do
    %{
      recipient: "quem@example.com",
      subject: "Assunto",
      body: "um link",
      kind: "reset_password",
      dedupe_key: "carteiro-#{System.unique_integer([:positive])}",
      expires_at: DateTime.add(DateTime.utc_now(:second), 3600)
    }
    |> Map.merge(Map.new(overrides))
  end

  defmodule RaisingAdapter do
    @moduledoc false

    @behaviour Swoosh.Adapter

    @impl Swoosh.Adapter
    def deliver(_email, _config), do: raise("o provedor explodiu")

    @impl Swoosh.Adapter
    def validate_config(_config), do: :ok
  end
end
