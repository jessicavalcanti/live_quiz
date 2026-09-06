defmodule LiveQuiz.Accounts.UserNotifier do
  @moduledoc """
  Delivers the account related emails.

  The bodies are written in pt-BR, since they are user facing.
  """

  import Swoosh.Email

  alias LiveQuiz.Mailer

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"Live Quiz", "nao-responda@livequiz.dev"})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to confirm the account.
  """
  def deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirme sua conta no Live Quiz", """

    ==============================

    Olá, #{user.name}!

    Você pode confirmar sua conta acessando o endereço abaixo:

    #{url}

    Se você não criou uma conta no Live Quiz, ignore este e-mail.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to reset the account password.
  """
  def deliver_reset_password_instructions(user, url) do
    deliver(user.email, "Redefinição de senha no Live Quiz", """

    ==============================

    Olá, #{user.name}!

    Você pode redefinir sua senha acessando o endereço abaixo:

    #{url}

    Se você não pediu a redefinição, ignore este e-mail.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Alteração de e-mail no Live Quiz", """

    ==============================

    Olá, #{user.name}!

    Você pode alterar seu e-mail acessando o endereço abaixo:

    #{url}

    Se você não pediu esta alteração, ignore este e-mail.

    ==============================
    """)
  end
end
