defmodule LiveQuiz.Accounts.GuardianTest do
  use LiveQuiz.DataCase, async: true

  import LiveQuiz.AccountsFixtures

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
      refute Map.has_key?(tokens, :refresh_token)

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
  end
end
