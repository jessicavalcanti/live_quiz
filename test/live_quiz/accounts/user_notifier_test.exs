defmodule LiveQuiz.Accounts.UserNotifierTest do
  @moduledoc """
  As três mensagens de conta: o que se grava e o que sai.

  A chamada devolve a **intenção**, não o e-mail, porque gravar e enviar
  deixaram de ser a mesma coisa (R07). No modo `:inline` dos testes a entrega
  acontece durante a chamada, então dá para afirmar sobre as duas metades: a
  linha que ficou registrada e a mensagem que saiu com o link certo.
  """

  use LiveQuiz.DataCase, async: true

  import Swoosh.TestAssertions
  import LiveQuiz.AccountsFixtures

  alias LiveQuiz.Accounts
  alias LiveQuiz.Mail
  alias LiveQuiz.Mail.Delivery

  describe "confirmation email" do
    test "is sent in pt-BR with the confirmation link" do
      user = unconfirmed_user_fixture()
      url = "http://localhost:4000/users/confirm/some-token"

      {:ok, %Delivery{} = delivery} =
        Accounts.deliver_user_confirmation_instructions(user, fn _token -> url end)

      assert delivery.kind == "confirmation"
      assert delivery.subject == "Confirme sua conta no Live Quiz"
      assert delivery.recipient == user.email
      assert delivery.body =~ user.name
      assert delivery.body =~ url

      assert_email_sent(fn email ->
        assert email.subject == "Confirme sua conta no Live Quiz"
        assert email.to == [{"", user.email}]
        assert email.text_body =~ url
      end)
    end

    test "nada fica pendente depois de entregue" do
      user = unconfirmed_user_fixture()

      {:ok, _delivery} =
        Accounts.deliver_user_confirmation_instructions(user, fn _token -> "http://x/y" end)

      # A tabela guarda o que ainda se deve, nunca um histórico: um link vivo
      # não fica no banco depois de a mensagem sair.
      assert Mail.pending_count() == 0
    end
  end

  describe "reset password email" do
    test "is sent in pt-BR with the reset link" do
      user = user_fixture()
      # Criar a conta já mandou a confirmação; sem esvaziar a caixa, a asserção
      # abaixo olharia para ela.
      flush_emails()
      url = "http://localhost:4000/users/reset-password/some-token"

      {:ok, %Delivery{} = delivery} =
        Accounts.deliver_user_reset_password_instructions(user, fn _token -> url end)

      assert delivery.kind == "reset_password"
      assert delivery.body =~ user.name
      assert delivery.body =~ url

      assert_email_sent(fn email ->
        assert email.subject == "Redefinição de senha no Live Quiz"
        assert email.to == [{"", user.email}]
        assert email.text_body =~ url
      end)
    end

    test "vale enquanto o link vale, e o link de senha dura um dia" do
      user = user_fixture()

      {:ok, delivery} =
        Accounts.deliver_user_reset_password_instructions(user, fn _token -> "http://x/y" end)

      # O prazo do envio é o prazo do link: insistir depois entregaria um
      # endereço morto, que é pior do que não entregar nada.
      assert DateTime.diff(delivery.expires_at, DateTime.utc_now(), :hour) in 23..24
    end
  end

  describe "update email email" do
    test "is sent in pt-BR with the confirmation link" do
      user = user_fixture()
      flush_emails()
      url = "http://localhost:4000/users/settings/confirm-email/some-token"

      {:ok, %Delivery{} = delivery} =
        Accounts.deliver_user_update_email_instructions(user, user.email, fn _token -> url end)

      assert delivery.kind == "update_email"
      assert delivery.body =~ url

      assert_email_sent(fn email ->
        assert email.subject == "Alteração de e-mail no Live Quiz"
        assert email.to == [{"", user.email}]
        assert email.text_body =~ url
      end)
    end
  end

  defp flush_emails do
    receive do
      {:email, _email} -> flush_emails()
    after
      0 -> :ok
    end
  end
end
