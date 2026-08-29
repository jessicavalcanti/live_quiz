defmodule LiveQuiz.Accounts.UserNotifierTest do
  use LiveQuiz.DataCase, async: true

  import Swoosh.TestAssertions
  import LiveQuiz.AccountsFixtures

  alias LiveQuiz.Accounts

  describe "confirmation email" do
    test "is sent in pt-BR with the confirmation link" do
      user = unconfirmed_user_fixture()
      url = "http://localhost:4000/users/confirm/some-token"

      {:ok, email} = Accounts.deliver_user_confirmation_instructions(user, fn _token -> url end)

      assert_email_sent(email)
      assert email.subject == "Confirme sua conta no Live Quiz"
      assert email.to == [{"", user.email}]
      assert email.text_body =~ user.name
      assert email.text_body =~ url
    end
  end

  describe "reset password email" do
    test "is sent in pt-BR with the reset link" do
      user = user_fixture()
      url = "http://localhost:4000/users/reset-password/some-token"

      {:ok, email} = Accounts.deliver_user_reset_password_instructions(user, fn _token -> url end)

      assert_email_sent(email)
      assert email.subject == "Redefinição de senha no Live Quiz"
      assert email.to == [{"", user.email}]
      assert email.text_body =~ user.name
      assert email.text_body =~ url
    end
  end

  describe "update email email" do
    test "is sent in pt-BR with the confirmation link" do
      user = user_fixture()
      url = "http://localhost:4000/users/settings/confirm-email/some-token"

      {:ok, email} =
        Accounts.deliver_user_update_email_instructions(user, user.email, fn _token -> url end)

      assert_email_sent(email)
      assert email.subject == "Alteração de e-mail no Live Quiz"
      assert email.to == [{"", user.email}]
      assert email.text_body =~ url
    end
  end
end
