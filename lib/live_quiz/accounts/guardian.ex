defmodule LiveQuiz.Accounts.Guardian do
  @moduledoc """
  Guardian implementation that issues and verifies the JWTs used by the JSON API.

  Two token types are emitted, both signed with the same secret and told apart by
  the `typ` claim:

    * `"access"` — short lived (15 minutes), the only one accepted by
      `LiveQuizWeb.Api.AuthPipeline`;
    * `"refresh"` — long lived (30 days), accepted only by `refresh_access_token/1`.

  There is no `Guardian.DB`: nothing is persisted and no query runs per request.
  The trade-off is that a leaked token stays valid until it expires — there is no
  server side revocation in this phase.
  """

  use Guardian, otp_app: :live_quiz

  alias LiveQuiz.Accounts
  alias LiveQuiz.Accounts.User

  @access_type "access"
  @refresh_type "refresh"
  @access_ttl {15, :minutes}
  @refresh_ttl {30, :days}
  @access_ttl_in_seconds 15 * 60

  @type tokens :: %{
          access_token: String.t(),
          refresh_token: String.t(),
          token_type: String.t(),
          expires_in: pos_integer()
        }

  @type access_token :: %{
          access_token: String.t(),
          token_type: String.t(),
          expires_in: pos_integer()
        }

  @impl Guardian
  def subject_for_token(%User{id: id}, _claims), do: {:ok, to_string(id)}
  def subject_for_token(_resource, _claims), do: {:error, :invalid_resource}

  @impl Guardian
  def resource_from_claims(%{"sub" => id}) do
    case Accounts.get_user(id) do
      %User{} = user -> {:ok, user}
      nil -> {:error, :unauthorized}
    end
  end

  def resource_from_claims(_claims), do: {:error, :unauthorized}

  @doc """
  Issues the access and refresh tokens of a freshly authenticated user.
  """
  @spec build_tokens(User.t()) :: {:ok, tokens()} | {:error, atom()}
  def build_tokens(%User{} = user) do
    with {:ok, access_token, _claims} <- encode_access_token(user),
         {:ok, refresh_token, _claims} <-
           encode_and_sign(user, %{}, token_type: @refresh_type, ttl: @refresh_ttl) do
      {:ok,
       %{
         access_token: access_token,
         refresh_token: refresh_token,
         token_type: "Bearer",
         expires_in: @access_ttl_in_seconds
       }}
    end
  end

  @doc """
  Exchanges a valid refresh token for a brand new access token.

  Anything else — a tampered token, an expired one, an access token used in its
  place or a token whose user no longer exists — returns
  `{:error, :invalid_refresh_token}`, so the caller cannot tell the cases apart.
  """
  @spec refresh_access_token(term()) :: {:ok, access_token()} | {:error, :invalid_refresh_token}
  def refresh_access_token(refresh_token) when is_binary(refresh_token) do
    with {:ok, claims} <- decode_and_verify(refresh_token, %{"typ" => @refresh_type}),
         {:ok, %User{} = user} <- resource_from_claims(claims),
         {:ok, access_token, _claims} <- encode_access_token(user) do
      {:ok,
       %{
         access_token: access_token,
         token_type: "Bearer",
         expires_in: @access_ttl_in_seconds
       }}
    else
      _error -> {:error, :invalid_refresh_token}
    end
  end

  def refresh_access_token(_refresh_token), do: {:error, :invalid_refresh_token}

  defp encode_access_token(%User{} = user) do
    encode_and_sign(user, %{}, token_type: @access_type, ttl: @access_ttl)
  end
end
