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

    test "renders 422 when the quiz reached the question limit" do
      conn = call({:error, :question_limit_reached})

      assert json_response(conn, 422) == %{
               "errors" => %{"detail" => "Este quiz já atingiu o limite de 50 perguntas"}
             }
    end

    test "renders 422 for a move direction that is neither up nor down" do
      conn = call({:error, :invalid_direction})

      assert json_response(conn, 422) == %{
               "errors" => %{"detail" => ~s(A direção deve ser "up" ou "down")}
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

    test "renders 403 for somebody identified who may not do this" do
      conn = call({:error, :unauthorized})

      assert json_response(conn, 403) == %{"errors" => %{"detail" => "Acesso negado"}}
    end

    test "renders 401 for a request the server could not identify" do
      conn = call({:error, :unauthenticated})

      assert json_response(conn, 401) == %{"errors" => %{"detail" => "Não autenticado"}}
    end

    test "renders 404 for a missing resource" do
      conn = call({:error, :not_found})

      assert json_response(conn, 404) == %{"errors" => %{"detail" => "Não encontrado"}}
    end

    test "renders 404 for a room that was not found" do
      conn = call({:error, :session_not_found})

      assert json_response(conn, 404) == %{"errors" => %{"detail" => "Não encontrado"}}
    end

    test "renders 422 for a quiz without questions" do
      conn = call({:error, :quiz_not_playable})

      assert json_response(conn, 422) == %{
               "errors" => %{"detail" => "O quiz precisa ter ao menos uma pergunta"}
             }
    end

    test "renders 409 for every conflict with the state of a room" do
      conflicts = [
        {:host_already_in_session, "Você já possui uma sala ativa"},
        {:already_participating, "Saia da sala em que você está para abrir uma nova"},
        {:session_not_joinable, "Esta partida já começou"},
        {:session_full, "Sala lotada"},
        {:nickname_taken, "Este apelido já está em uso nesta sala"},
        {:already_in_another_session, "Você já está participando de outra sala"},
        {:no_connected_participants, "É preciso ao menos um participante conectado"},
        {:invalid_transition, "Esta sala já foi encerrada"}
      ]

      for {reason, detail} <- conflicts do
        conn = call({:error, reason})

        assert json_response(conn, 409) == %{"errors" => %{"detail" => detail}},
               "#{inspect(reason)} deveria responder 409 com #{inspect(detail)}"
      end
    end

    test "renders 410 for a room that is over" do
      conn = call({:error, :session_ended})

      assert json_response(conn, 410) == %{"errors" => %{"detail" => "Esta sala foi encerrada"}}
    end

    test "renders 503 when no join code could be generated" do
      conn = call({:error, :code_generation_failed})

      assert json_response(conn, 503) == %{
               "errors" => %{"detail" => "Não foi possível gerar um código. Tente novamente."}
             }
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
