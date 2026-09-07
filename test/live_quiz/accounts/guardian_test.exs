defmodule LiveQuiz.Accounts.GuardianTest do
  use LiveQuiz.DataCase, async: true

  import LiveQuiz.AccountsFixtures

  alias LiveQuiz.Accounts
  alias LiveQuiz.Accounts.Guardian
  alias LiveQuiz.Accounts.User

  describe "subject_for_token/2" do
    test "uses the user id as the subject" do
      user = user_fixture()

      assert Guardian.subject_for_token(user, %{}) == {:ok, to_string(user.id)}
    end

    test "refuses anything that is not a user" do
      assert Guardian.subject_for_token(%{id: 1}, %{}) == {:error, :invalid_resource}
    end
  end

  describe "resource_from_claims/1" do
    test "loads the user of the sub claim" do
      user = user_fixture()

      assert {:ok, %User{id: id}} = Guardian.resource_from_claims(%{"sub" => to_string(user.id)})
      assert id == user.id
    end

    test "returns unauthorized when the user does not exist" do
      assert Guardian.resource_from_claims(%{"sub" => "0"}) == {:error, :unauthorized}
    end

    test "returns unauthorized when the sub is not an id" do
      assert Guardian.resource_from_claims(%{"sub" => "abc"}) == {:error, :unauthorized}
    end

    test "returns unauthorized when there is no sub claim" do
      assert Guardian.resource_from_claims(%{"typ" => "access"}) == {:error, :unauthorized}
    end
  end

  describe "build_tokens/1" do
    test "issues an access and a refresh token with distinct typ claims" do
      user = user_fixture()

      assert {:ok, tokens} = Guardian.build_tokens(user)
      assert tokens.token_type == "Bearer"
      assert tokens.expires_in == 900

      assert {:ok, %{"typ" => "access", "sub" => sub}} =
               Guardian.decode_and_verify(tokens.access_token, %{"typ" => "access"})

      assert sub == to_string(user.id)

      assert {:ok, %{"typ" => "refresh"}} =
               Guardian.decode_and_verify(tokens.refresh_token, %{"typ" => "refresh"})
    end

    test "the refresh token lives much longer than the access token" do
      user = user_fixture()

      assert {:ok, tokens} = Guardian.build_tokens(user)
      assert {:ok, access_claims} = Guardian.decode_and_verify(tokens.access_token)
      assert {:ok, refresh_claims} = Guardian.decode_and_verify(tokens.refresh_token)

      assert refresh_claims["exp"] - access_claims["exp"] > 29 * 24 * 60 * 60
    end
  end

  describe "refresh_access_token/1" do
    test "issues a new access token from a valid refresh token" do
      user = user_fixture()
      {:ok, %{refresh_token: refresh_token}} = Guardian.build_tokens(user)

      assert {:ok, tokens} = Guardian.refresh_access_token(refresh_token)
      assert tokens.token_type == "Bearer"
      assert tokens.expires_in == 900

      # A renovação também devolve um refresh novo: a sessão é uma corrente, e
      # é ela que torna um replay visível (R03).
      assert is_binary(tokens.refresh_token)
      refute tokens.refresh_token == refresh_token

      assert {:ok, %{"typ" => "access", "sub" => sub}} =
               Guardian.decode_and_verify(tokens.access_token, %{"typ" => "access"})

      assert sub == to_string(user.id)
    end

    test "refuses an access token" do
      user = user_fixture()
      {:ok, %{access_token: access_token}} = Guardian.build_tokens(user)

      assert Guardian.refresh_access_token(access_token) == {:error, :invalid_refresh_token}
    end

    test "refuses a tampered token" do
      user = user_fixture()
      {:ok, %{refresh_token: refresh_token}} = Guardian.build_tokens(user)

      assert Guardian.refresh_access_token(refresh_token <> "x") ==
               {:error, :invalid_refresh_token}
    end

    test "refuses a refresh token whose user was removed" do
      user = user_fixture()
      {:ok, %{refresh_token: refresh_token}} = Guardian.build_tokens(user)
      Repo.delete!(user)

      assert Guardian.refresh_access_token(refresh_token) == {:error, :invalid_refresh_token}
    end

    test "refuses anything that is not a string" do
      assert Guardian.refresh_access_token(nil) == {:error, :invalid_refresh_token}
    end

    test "refuses a refresh token the server never issued" do
      user = user_fixture()

      {:ok, unregistered, _claims} =
        Guardian.encode_and_sign(user, %{}, token_type: "refresh", ttl: {30, :days})

      # Signed with the right secret, and still not a session: a family opens at
      # login, and nothing else counts as one (R03).
      assert Guardian.refresh_access_token(unregistered) == {:error, :invalid_refresh_token}
    end

    test "spends the presented token, so the same one cannot renew twice" do
      user = user_fixture()
      {:ok, %{refresh_token: first}} = Guardian.build_tokens(user)

      assert {:ok, %{refresh_token: second}} = Guardian.refresh_access_token(first)
      refute second == first

      assert Guardian.refresh_access_token(first) == {:error, :invalid_refresh_token}
    end

    test "a replayed token ends the whole family, including the link in use" do
      user = user_fixture()
      {:ok, %{refresh_token: first}} = Guardian.build_tokens(user)
      {:ok, %{refresh_token: second}} = Guardian.refresh_access_token(first)

      # The replay itself is refused, and so is the token the rightful holder
      # has: two holders spent one row, and there is no telling which is which,
      # so the session ends for both and the person logs in again.
      assert Guardian.refresh_access_token(first) == {:error, :invalid_refresh_token}
      assert Guardian.refresh_access_token(second) == {:error, :invalid_refresh_token}
    end

    test "keeps the sessions of other accounts out of it" do
      user = user_fixture()
      other = user_fixture()

      {:ok, %{refresh_token: theirs}} = Guardian.build_tokens(other)
      {:ok, %{refresh_token: first}} = Guardian.build_tokens(user)
      {:ok, _rotated} = Guardian.refresh_access_token(first)
      {:error, :invalid_refresh_token} = Guardian.refresh_access_token(first)

      assert {:ok, _tokens} = Guardian.refresh_access_token(theirs)
    end
  end

  describe "revoke_session/1" do
    test "ends the family the token belongs to" do
      user = user_fixture()
      {:ok, %{refresh_token: first}} = Guardian.build_tokens(user)
      {:ok, %{refresh_token: second}} = Guardian.refresh_access_token(first)

      assert Guardian.revoke_session(second) == :ok
      assert Guardian.refresh_access_token(second) == {:error, :invalid_refresh_token}
    end

    test "leaves the other sessions of the same account alone" do
      user = user_fixture()
      {:ok, %{refresh_token: laptop}} = Guardian.build_tokens(user)
      {:ok, %{refresh_token: phone}} = Guardian.build_tokens(user)

      assert Guardian.revoke_session(laptop) == :ok

      # Logging out of one device is one device: that is the whole reason a
      # family is per login rather than per account (R03).
      assert {:ok, _tokens} = Guardian.refresh_access_token(phone)
    end

    test "stays quiet about a token it does not recognise" do
      assert Guardian.revoke_session("nonsense") == :ok
      assert Guardian.revoke_session(nil) == :ok
    end
  end

  describe "the ver claim" do
    test "travels on the access token and matches the account" do
      user = user_fixture()
      {:ok, %{access_token: access_token}} = Guardian.build_tokens(user)

      assert {:ok, %{"ver" => version}} = Guardian.decode_and_verify(access_token)
      assert version == user.auth_version

      assert {:ok, %User{id: id}} =
               Guardian.resource_from_claims(%{"sub" => to_string(user.id), "ver" => version})

      assert id == user.id
    end

    test "rejects an access token issued before the account was revoked" do
      user = user_fixture()
      {:ok, %{access_token: access_token}} = Guardian.build_tokens(user)
      {:ok, _revoked} = Accounts.revoke_all_api_sessions(user)

      assert {:ok, claims} = Guardian.decode_and_verify(access_token)
      assert Guardian.resource_from_claims(claims) == {:error, :unauthorized}
    end

    test "accepts a token minted before the claim existed, while the account is untouched" do
      user = user_fixture()

      {:ok, _legacy, claims} =
        Guardian.encode_and_sign(user, %{}, token_type: "access", ttl: {15, :minutes})

      refute Map.has_key?(claims, "ver")
      assert {:ok, %User{}} = Guardian.resource_from_claims(claims)

      # And that grace closes the moment the account is revoked, rather than
      # outliving it.
      {:ok, _revoked} = Accounts.revoke_all_api_sessions(user)
      assert Guardian.resource_from_claims(claims) == {:error, :unauthorized}
    end
  end
end
