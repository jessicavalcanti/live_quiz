defmodule LiveQuiz.Accounts.UserNotifier do
  @moduledoc """
  Writes the account emails. Does not send them.

  Rendering and sending were the same call, so a slow provider was a slow
  screen and a provider that was down was a screen that said the message had
  gone out (R07). This module now only produces the subject and the body;
  `LiveQuiz.Mail` writes the intent down and `LiveQuiz.Mail.Courier` delivers
  it.

  The bodies are written in pt-BR, since they are user facing.
  """

  alias LiveQuiz.Accounts.User

  @type message :: %{subject: String.t(), body: String.t()}

  @doc "The message that confirms an account."
  @spec confirmation_instructions(User.t(), String.t()) :: message()
  def confirmation_instructions(%User{} = user, url) do
    %{
      subject: "Confirme sua conta no Live Quiz",
      body: """

      ==============================

      Olá, #{user.name}!

      Você pode confirmar sua conta acessando o endereço abaixo:

      #{url}

      Se você não criou uma conta no Live Quiz, ignore este e-mail.

      ==============================
      """
    }
  end

  @doc "The message that resets a password."
  @spec reset_password_instructions(User.t(), String.t()) :: message()
  def reset_password_instructions(%User{} = user, url) do
    %{
      subject: "Redefinição de senha no Live Quiz",
      body: """

      ==============================

      Olá, #{user.name}!

      Você pode redefinir sua senha acessando o endereço abaixo:

      #{url}

      Se você não pediu a redefinição, ignore este e-mail.

      ==============================
      """
    }
  end

  @doc "The message that confirms a change of address."
  @spec update_email_instructions(User.t(), String.t()) :: message()
  def update_email_instructions(%User{} = user, url) do
    %{
      subject: "Alteração de e-mail no Live Quiz",
      body: """

      ==============================

      Olá, #{user.name}!

      Você pode alterar seu e-mail acessando o endereço abaixo:

      #{url}

      Se você não pediu esta alteração, ignore este e-mail.

      ==============================
      """
    }
  end
end
