defmodule LiveQuiz.MailTest do
  @moduledoc """
  A caixa de saída: o que se grava, o que se entrega e o que se desiste (R07).
  """

  use LiveQuiz.DataCase, async: true

  import LiveQuiz.AccountsFixtures
  import Swoosh.TestAssertions

  alias LiveQuiz.Mail
  alias LiveQuiz.Mail.Delivery

  describe "record/1" do
    test "guarda a conta a que a mensagem pertence" do
      user = user_fixture()

      {:ok, delivery} = Mail.record(intent(user_id: user.id))

      assert delivery.user_id == user.id
    end

    test "grava a intenção sem enviar nada" do
      assert {:ok, %Delivery{} = delivery} = Mail.record(intent())

      assert delivery.attempts == 0
      assert Mail.pending_count() == 1
      assert_no_email_sent()
    end

    test "a mesma chave grava uma mensagem só" do
      assert {:ok, first} = Mail.record(intent(dedupe_key: "mesma"))
      assert {:ok, second} = Mail.record(intent(dedupe_key: "mesma", subject: "outro assunto"))

      # Um duplo clique, ou uma transação repetida, devem uma mensagem — não
      # duas. O primeiro registro é o que vale.
      assert second.id == first.id
      assert second.subject == first.subject
      assert Mail.pending_count() == 1
    end

    test "chaves diferentes são mensagens diferentes" do
      {:ok, _first} = Mail.record(intent(dedupe_key: "uma"))
      {:ok, _second} = Mail.record(intent(dedupe_key: "outra"))

      assert Mail.pending_count() == 2
    end
  end

  describe "drain/1" do
    test "entrega o que está vencido e apaga a linha" do
      {:ok, _delivery} = Mail.record(intent(subject: "Assunto de teste"))

      assert Mail.drain() == 1

      assert_email_sent(fn email ->
        assert email.subject == "Assunto de teste"
        assert email.to == [{"", "quem@example.com"}]
      end)

      # Nada de histórico: um link vivo não fica guardado depois de sair.
      assert Mail.pending_count() == 0
    end

    test "não toca no que ainda não venceu" do
      {:ok, _delivery} =
        Mail.record(intent(deliver_after: DateTime.add(DateTime.utc_now(:second), 3600)))

      assert Mail.drain() == 0
      assert Mail.pending_count() == 1
      assert_no_email_sent()
    end

    test "entrega mais do que cabe em um lote" do
      for index <- 1..25, do: Mail.record(intent(dedupe_key: "lote-#{index}"))

      assert Mail.drain() == 25
      assert Mail.pending_count() == 0
    end

    test "descarta o que já não vale sem tentar enviar" do
      {:ok, _delivery} =
        Mail.record(intent(expires_at: DateTime.add(DateTime.utc_now(:second), -1)))

      handler = attach([:live_quiz, :mail, :expired])

      assert Mail.drain() == 0

      # Entregar um link morto é pior do que não entregar: a pessoa lê a falha
      # como sendo dela.
      assert_receive {:mail_event, [:live_quiz, :mail, :expired], %{kind: "reset_password"}}
      assert_no_email_sent()
      assert Mail.pending_count() == 0

      :telemetry.detach(handler)
    end
  end

  describe "quando o provedor recusa" do
    setup :failing_mailer

    test "a mensagem continua devida e volta a ser tentada depois" do
      {:ok, delivery} = Mail.record(intent())
      handler = attach([:live_quiz, :mail, :failed])

      assert Mail.drain() == 0

      assert_receive {:mail_event, [:live_quiz, :mail, :failed], %{kind: "reset_password"}}

      pending = Repo.get!(Delivery, delivery.id)
      assert pending.attempts == 1
      assert pending.last_error =~ "recusado"
      # O backoff está na coluna, não em um processo que um restart esqueceria.
      assert DateTime.compare(pending.deliver_after, DateTime.utc_now()) == :gt

      :telemetry.detach(handler)
    end

    test "desiste depois do número de tentativas, e diz que desistiu" do
      {:ok, delivery} = Mail.record(intent())
      handler = attach([:live_quiz, :mail, :exhausted])

      for _attempt <- 1..Mail.max_attempts() do
        # Cada passagem encontra a mensagem vencida de novo, que é o que o
        # relógio faria depois de cada backoff.
        make_due(delivery)
        Mail.drain()
      end

      assert_receive {:mail_event, [:live_quiz, :mail, :exhausted], %{kind: "reset_password"}}
      assert Mail.pending_count() == 0

      :telemetry.detach(handler)
    end

    test "uma tentativa gasta é uma tentativa gasta, mesmo se o carteiro morrer" do
      {:ok, delivery} = Mail.record(intent())

      Mail.drain()

      # A linha é reivindicada antes do envio: um carteiro morto no meio custa
      # uma tentativa, não uma linha presa para sempre.
      assert Repo.get!(Delivery, delivery.id).attempts == 1
    end
  end

  describe "deliver_soon/0" do
    test "no modo :inline entrega na própria chamada" do
      assert Mail.mode() == :inline

      {:ok, _delivery} = Mail.record(intent())
      Mail.deliver_soon()

      assert_email_sent()
      assert Mail.pending_count() == 0
    end
  end

  describe "o corpo e o endereço" do
    test "não aparecem na telemetria" do
      {:ok, _delivery} = Mail.record(intent(body: "http://exemplo/reset/segredo-vivo"))
      handler = attach([:live_quiz, :mail, :sent])

      Mail.drain()

      assert_receive {:mail_event, [:live_quiz, :mail, :sent], metadata}
      # O que se mede é o tipo da mensagem. O corpo é um link vivo e o endereço
      # é a pessoa; nenhum dos dois tem o que fazer em uma métrica.
      assert Map.keys(metadata) == [:kind]

      :telemetry.detach(handler)
    end
  end

  # Sem fixture de usuário de propósito: criar uma conta manda um e-mail, e no
  # modo `:inline` esse envio drena a caixa inteira — inclusive as intenções que
  # este teste acabou de gravar.
  defp intent(overrides \\ []) do
    %{
      recipient: "quem@example.com",
      subject: "Redefinição de senha no Live Quiz",
      body: "um link",
      kind: "reset_password",
      dedupe_key: "chave-#{System.unique_integer([:positive])}",
      expires_at: DateTime.add(DateTime.utc_now(:second), 86_400)
    }
    |> Map.merge(Map.new(overrides))
  end

  # O adaptador de teste do Swoosh recusa quando o e-mail pede: é o jeito de ter
  # um provedor indisponível sem esperar por um.
  defp failing_mailer(_context) do
    Application.put_env(:live_quiz, LiveQuiz.Mailer, adapter: LiveQuiz.MailTest.RefusingAdapter)

    on_exit(fn ->
      Application.put_env(:live_quiz, LiveQuiz.Mailer, adapter: Swoosh.Adapters.Test)
    end)

    :ok
  end

  defp make_due(%Delivery{id: id}) do
    Repo.update_all(
      from(d in Delivery, where: d.id == ^id),
      set: [deliver_after: DateTime.add(DateTime.utc_now(:second), -1)]
    )
  end

  defp attach(event) do
    handler = "mail-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      handler,
      event,
      fn name, _measurements, metadata, _config ->
        send(test, {:mail_event, name, metadata})
      end,
      nil
    )

    handler
  end

  defmodule RefusingAdapter do
    @moduledoc false

    @behaviour Swoosh.Adapter

    @impl Swoosh.Adapter
    def deliver(_email, _config), do: {:error, "provedor recusado"}

    @impl Swoosh.Adapter
    def validate_config(_config), do: :ok
  end
end
