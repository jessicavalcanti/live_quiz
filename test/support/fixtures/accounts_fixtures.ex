defmodule LiveQuiz.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `LiveQuiz.Accounts` context.
  """

  import Ecto.Query

  alias LiveQuiz.Accounts
  alias LiveQuiz.Accounts.Scope

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def valid_user_name, do: "Ana Souza"
  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: valid_user_name(),
      email: unique_user_email(),
      password: valid_user_password(),
      password_confirmation: valid_user_password()
    })
  end

  def unconfirmed_user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Accounts.register_user()

    user
  end

  def user_fixture(attrs \\ %{}) do
    user = unconfirmed_user_fixture(attrs)

    token =
      extract_user_token(fn url ->
        Accounts.deliver_user_confirmation_instructions(user, url)
      end)

    {:ok, user} = Accounts.confirm_user(token)

    user
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end

  # O que a chamada devolve agora é a intenção gravada, não o e-mail enviado
  # (R07). O corpo é o mesmo, e é dele que o token sai — o envio em si acontece
  # no modo `:inline` durante a chamada, então quem quiser afirmar sobre a
  # entrega ainda tem `assert_email_sent/0`.
  def extract_user_token(fun) do
    {:ok, %LiveQuiz.Mail.Delivery{body: body}} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    LiveQuiz.Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_user_reset_password_token(user) do
    {encoded_token, user_token} = Accounts.UserToken.build_email_token(user, "reset_password")
    LiveQuiz.Repo.insert!(user_token)
    {encoded_token, user_token.token}
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    LiveQuiz.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
