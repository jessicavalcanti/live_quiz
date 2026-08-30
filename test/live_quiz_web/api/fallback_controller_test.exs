defmodule LiveQuizWeb.Api.FallbackControllerTest do
  use LiveQuizWeb.ConnCase, async: true

  alias LiveQuizWeb.Api.ErrorJSON
  alias LiveQuizWeb.Api.FallbackController

  defp call(error) do
    Phoenix.ConnTest.build_conn()
    |> Phoenix.Controller.accepts(["json"])
    |> FallbackController.call(error)
  end

  describe "call/2" do
    test "renders 422 with the translated field errors of a changeset" do
      changeset =
        {%{}, %{email: :string}}
        |> Ecto.Changeset.cast(%{}, [:email])
        |> Ecto.Changeset.validate_required([:email])

      conn = call({:error, changeset})

      assert json_response(conn, 422) == %{
               "errors" => %{"email" => ["não pode ficar em branco"]}
             }
    end

    test "renders 401 for invalid credentials" do
      conn = call({:error, :invalid_credentials})

      assert json_response(conn, 401) == %{"errors" => %{"detail" => "E-mail ou senha inválidos"}}
    end

    test "renders 401 for an invalid refresh token" do
      conn = call({:error, :invalid_refresh_token})

      assert json_response(conn, 401) == %{
               "errors" => %{"detail" => "Refresh token inválido ou expirado"}
             }
    end

    test "renders 401 for an unauthorized request" do
      conn = call({:error, :unauthorized})

      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Não autenticado"}}
    end

    test "renders 404 for a missing resource" do
      conn = call({:error, :not_found})

      assert json_response(conn, 404) == %{"errors" => %{"detail" => "Não encontrado"}}
    end
  end

  describe "ErrorJSON" do
    test "renders a plain message" do
      assert ErrorJSON.render("error.json", %{detail: "Deu ruim"}) == %{
               errors: %{detail: "Deu ruim"}
             }
    end

    test "renders the pt-BR message of the known statuses" do
      assert ErrorJSON.render("401.json", %{}) == %{errors: %{detail: "Não autenticado"}}
      assert ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Não encontrado"}}
    end

    test "falls back to the status message of the template" do
      assert ErrorJSON.render("500.json", %{}) == %{
               errors: %{detail: "Internal Server Error"}
             }
    end
  end
end
