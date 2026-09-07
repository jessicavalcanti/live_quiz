defmodule LiveQuiz.Accounts.Guardian do
  @moduledoc """
  Guardian implementation that issues and verifies the JWTs used by the JSON API.

  Two token types are emitted, both signed with the same secret and told apart by
  the `typ` claim:

    * `"access"` — short lived (15 minutes), the only one accepted by
      `LiveQuizWeb.Api.AuthPipeline`;
    * `"refresh"` — long lived (30 days), accepted only by `refresh_access_token/1`.

  There is no `Guardian.DB`: no *token* is persisted, and a token is not looked
  up to be verified — the signature is what proves it. `resource_from_claims/1`
  does read the account the `sub` names, on every authenticated request, because
  an account that was deleted must stop working immediately; saying that no
  query runs per request was simply wrong (R43).

  Revocation is what a self-proving token does not have on its own, and there
  are two questions worth answering separately (R03):

    * **this device** — every login opens a refresh *family* in
      `refresh_tokens`, and refreshing rotates it: the presented token is spent
      and the next one takes its place. A token spent twice is a token that was
      replayed, and the family is revoked rather than guessing which of the two
      holders is the thief. Logging out revokes the family.
    * **every device** — `users.auth_version` travels in the access token as
      `ver` and is compared on every request. Moving it rejects every access
      token already issued, at once. It costs nothing per request: the account
      row is read to resolve the subject either way.

  Resetting a password does both, which is what makes "I think somebody has my
  password" an action the person can actually take.
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
  def resource_from_claims(%{"sub" => id} = claims) do
    case Accounts.get_user(id) do
      %User{} = user -> match_auth_version(user, claims)
      nil -> {:error, :unauthorized}
    end
  end

  def resource_from_claims(_claims), do: {:error, :unauthorized}

  # A token issued before the account's authentication was invalidated names a
  # version that no longer matches. Refresh tokens carry no version: they are
  # revoked by their row, and checking both would end a session twice for one
  # reason.
  defp match_auth_version(%User{} = user, %{"typ" => @refresh_type}), do: {:ok, user}

  defp match_auth_version(%User{auth_version: version} = user, %{"ver" => version}),
    do: {:ok, user}

  # A token minted before this claim existed was minted when the account's
  # version was necessarily zero, so that is what it means — an upgrade path
  # rather than an exception, and one that closes on its own as those tokens
  # expire.
  defp match_auth_version(%User{auth_version: 0} = user, claims)
       when not is_map_key(claims, "ver"),
       do: {:ok, user}

  defp match_auth_version(%User{}, _stale_version), do: {:error, :unauthorized}

  @doc """
  Issues the access and refresh tokens of a freshly authenticated user.
  """
  @spec build_tokens(User.t()) :: {:ok, tokens()} | {:error, atom()}
  def build_tokens(%User{} = user) do
    with {:ok, access_token, _claims} <- encode_access_token(user),
         {:ok, refresh_token, claims} <- encode_refresh_token(user),
         {:ok, _row} <- Accounts.start_refresh_family(user, refresh_token, expiry(claims)) do
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
  @spec refresh_access_token(term()) :: {:ok, tokens()} | {:error, :invalid_refresh_token}
  def refresh_access_token(refresh_token) when is_binary(refresh_token) do
    with {:ok, claims} <- decode_and_verify(refresh_token, %{"typ" => @refresh_type}),
         {:ok, %User{} = user} <- resource_from_claims(claims),
         {:ok, access_token, _access_claims} <- encode_access_token(user),
         {:ok, next_refresh, next_claims} <- encode_refresh_token(user),
         :ok <- Accounts.rotate_refresh_token(refresh_token, next_refresh, expiry(next_claims)) do
      {:ok,
       %{
         access_token: access_token,
         refresh_token: next_refresh,
         token_type: "Bearer",
         expires_in: @access_ttl_in_seconds
       }}
    else
      _error -> {:error, :invalid_refresh_token}
    end
  end

  def refresh_access_token(_refresh_token), do: {:error, :invalid_refresh_token}

  @doc """
  Ends the session the refresh token belongs to.

  Revoking the family rather than the row: the point of logging out is that the
  chain stops, and the next link is exactly what a rotation would have issued.
  """
  @spec revoke_session(term()) :: :ok
  def revoke_session(refresh_token) when is_binary(refresh_token),
    do: Accounts.revoke_refresh_family(refresh_token)

  def revoke_session(_refresh_token), do: :ok

  # `ver` is what makes a global revocation immediate. It is on the access token
  # only: a refresh token is revoked by its row, and carrying both would end a
  # session twice for one reason.
  defp encode_access_token(%User{auth_version: version} = user) do
    encode_and_sign(user, %{"ver" => version}, token_type: @access_type, ttl: @access_ttl)
  end

  defp encode_refresh_token(%User{} = user) do
    encode_and_sign(user, %{}, token_type: @refresh_type, ttl: @refresh_ttl)
  end

  defp expiry(%{"exp" => exp}), do: DateTime.from_unix!(exp)
end
