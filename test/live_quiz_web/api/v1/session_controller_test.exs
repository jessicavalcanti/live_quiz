defmodule LiveQuizWeb.Api.V1.SessionControllerTest do
  use LiveQuizWeb.ConnCase, async: true

  import LiveQuiz.AccountsFixtures

  alias LiveQuiz.Accounts.Guardian

  @unauthorized %{"errors" => %{"detail" => "Não autenticado"}}
  @invalid_credentials %{"errors" => %{"detail" => "E-mail ou senha inválidos"}}
  @invalid_refresh %{"errors" => %{"detail" => "Refresh token inválido ou expirado"}}

  describe "POST /api/v1/session" do
    test "returns 201 with both tokens and the user data", %{conn: conn} do
      user = user_fixture()

      conn =
        post(conn, ~p"/api/v1/session", %{
          "email" => user.email,
          "password" => valid_user_password()
        })

      assert %{"data" => data} = json_response(conn, 201)

      assert %{
               "access_token" => access_token,
               "refresh_token" => refresh_token,
               "token_type" => "Bearer",
               "expires_in" => 900,
               "user" => user_data
             } = data

      assert is_binary(access_token)
      assert is_binary(refresh_token)
      assert user_data == %{"id" => user.id, "name" => user.name, "email" => user.email}
      refute Map.has_key?(user_data, "hashed_password")
    end

    test "issues an access token that is accepted by a protected route", %{conn: conn} do
      user = user_fixture()

      conn =
        post(conn, ~p"/api/v1/session", %{
          "email" => user.email,
          "password" => valid_user_password()
        })

      %{"data" => %{"access_token" => access_token}} = json_response(conn, 201)

      me_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> access_token)
        |> get(~p"/api/v1/me")

      assert %{"data" => %{"id" => id}} = json_response(me_conn, 200)
      assert id == user.id
    end

    test "returns 401 with a generic message when the password is wrong", %{conn: conn} do
      user = user_fixture()

      conn = post(conn, ~p"/api/v1/session", %{"email" => user.email, "password" => "errada"})

      assert json_response(conn, 401) == @invalid_credentials
    end

    test "returns the very same message when the email does not exist", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/session", %{
          "email" => "ninguem@example.com",
          "password" => valid_user_password()
        })

      assert json_response(conn, 401) == @invalid_credentials
    end

    test "returns no token when the credentials are invalid", %{conn: conn} do
      user = user_fixture()

      conn = post(conn, ~p"/api/v1/session", %{"email" => user.email, "password" => "errada"})

      body = json_response(conn, 401)
      refute Map.has_key?(body, "data")
      refute body["errors"]["access_token"]
    end

    test "returns 422 when the password is missing", %{conn: conn} do
      user = user_fixture()

      conn = post(conn, ~p"/api/v1/session", %{"email" => user.email})

      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["password"] == ["não pode ficar em branco"]
      refute Map.has_key?(errors, "email")
    end

    test "returns 422 when both fields are missing", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/session", %{})

      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["email"] == ["não pode ficar em branco"]
      assert errors["password"] == ["não pode ficar em branco"]
    end

    test "authenticates a user whose email was never confirmed", %{conn: conn} do
      user = unconfirmed_user_fixture()

      conn =
        post(conn, ~p"/api/v1/session", %{
          "email" => user.email,
          "password" => valid_user_password()
        })

      assert %{"data" => %{"access_token" => access_token}} = json_response(conn, 201)
      assert is_binary(access_token)
    end
  end

  describe "GET /api/v1/me" do
    setup :register_and_log_in_api_user

    test "returns 200 with the authenticated user", %{conn: conn, user: user} do
      conn = get(conn, ~p"/api/v1/me")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "id" => user.id,
                 "name" => user.name,
                 "email" => user.email,
                 "confirmed" => true
               }
             }
    end

    test "reports an unconfirmed user as not confirmed" do
      user = unconfirmed_user_fixture()

      conn =
        build_conn()
        |> log_in_api_user(user)
        |> get(~p"/api/v1/me")

      assert %{"data" => %{"confirmed" => false}} = json_response(conn, 200)
    end
  end

  describe "GET /api/v1/me without a usable token" do
    test "returns 401 when there is no authorization header", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/me")

      assert json_response(conn, 401) == @unauthorized
    end

    test "returns 401 when the token is malformed", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer nao-e-um-jwt")
        |> get(~p"/api/v1/me")

      assert json_response(conn, 401) == @unauthorized
    end

    test "returns 401 when the token was signed with another secret", %{conn: conn} do
      user = user_fixture()
      tampered = api_token(user) <> "x"

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> tampered)
        |> get(~p"/api/v1/me")

      assert json_response(conn, 401) == @unauthorized
    end

    test "returns 401 when the access token is expired", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> log_in_api_user(user, ttl: {-1, :minute})
        |> get(~p"/api/v1/me")

      assert json_response(conn, 401) == @unauthorized
    end

    test "returns 401 when a refresh token is sent as the access token", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> log_in_api_user(user, token_type: "refresh", ttl: {30, :days})
        |> get(~p"/api/v1/me")

      assert json_response(conn, 401) == @unauthorized
    end

    test "returns 401 when the user of the token no longer exists", %{conn: conn} do
      user = user_fixture()
      token = api_token(user)
      LiveQuiz.Repo.delete!(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> get(~p"/api/v1/me")

      assert json_response(conn, 401) == @unauthorized
    end
  end

  describe "POST /api/v1/session/refresh" do
    test "returns 200 with a new access token", %{conn: conn} do
      user = user_fixture()
      refresh_token = api_token(user, token_type: "refresh", ttl: {30, :days})

      conn = post(conn, ~p"/api/v1/session/refresh", %{"refresh_token" => refresh_token})

      assert %{"data" => data} = json_response(conn, 200)

      assert %{
               "access_token" => access_token,
               "token_type" => "Bearer",
               "expires_in" => 900
             } = data

      me_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> access_token)
        |> get(~p"/api/v1/me")

      assert %{"data" => %{"id" => id}} = json_response(me_conn, 200)
      assert id == user.id
    end

    test "returns 401 when the refresh token is tampered with", %{conn: conn} do
      user = user_fixture()
      tampered = api_token(user, token_type: "refresh", ttl: {30, :days}) <> "x"

      conn = post(conn, ~p"/api/v1/session/refresh", %{"refresh_token" => tampered})

      assert json_response(conn, 401) == @invalid_refresh
    end

    test "returns 401 when the refresh token is expired", %{conn: conn} do
      user = user_fixture()
      expired = api_token(user, token_type: "refresh", ttl: {-1, :minute})

      conn = post(conn, ~p"/api/v1/session/refresh", %{"refresh_token" => expired})

      assert json_response(conn, 401) == @invalid_refresh
    end

    test "returns 401 when an access token is sent as the refresh token", %{conn: conn} do
      user = user_fixture()

      conn = post(conn, ~p"/api/v1/session/refresh", %{"refresh_token" => api_token(user)})

      assert json_response(conn, 401) == @invalid_refresh
    end

    test "returns 401 when the refresh token is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/session/refresh", %{})

      assert json_response(conn, 401) == @invalid_refresh
    end
  end

  describe "DELETE /api/v1/session" do
    test "returns 204 with a valid access token", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> log_in_api_user(user)
        |> delete(~p"/api/v1/session")

      assert response(conn, 204) == ""
    end

    test "returns 401 without a token", %{conn: conn} do
      conn = delete(conn, ~p"/api/v1/session")

      assert json_response(conn, 401) == @unauthorized
    end
  end

  describe "error envelope" do
    test "every error answers with a top level errors key", %{conn: conn} do
      user = user_fixture()

      responses = [
        conn |> post(~p"/api/v1/session", %{"email" => user.email, "password" => "x"}),
        conn |> post(~p"/api/v1/session", %{}),
        conn |> get(~p"/api/v1/me"),
        conn |> post(~p"/api/v1/session/refresh", %{"refresh_token" => "quebrado"})
      ]

      for response <- responses do
        assert %{"errors" => errors} = Jason.decode!(response.resp_body)
        assert Map.keys(Jason.decode!(response.resp_body)) == ["errors"]
        assert is_map(errors)
      end
    end
  end

  describe "token contract" do
    test "the access token carries the user id in the sub claim", %{conn: conn} do
      user = user_fixture()

      conn =
        post(conn, ~p"/api/v1/session", %{
          "email" => user.email,
          "password" => valid_user_password()
        })

      %{"data" => %{"access_token" => access_token}} = json_response(conn, 201)

      assert {:ok, claims} = Guardian.decode_and_verify(access_token, %{"typ" => "access"})
      assert claims["sub"] == to_string(user.id)
      assert claims["iss"] == "live_quiz"
    end
  end
end
