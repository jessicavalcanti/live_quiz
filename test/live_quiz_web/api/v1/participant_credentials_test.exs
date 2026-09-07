defmodule LiveQuizWeb.Api.V1.ParticipantCredentialsTest do
  @moduledoc """
  Which credential a request is about, and which ones it merely holds.

  Regression for R27 of the review. `rejoin` resolved the room from the first
  credential that named any participation and told the context about that one
  alone — so a guest holding two had the room picked by the order of its
  headers, and the exclusivity check was answered with the one identity that
  cannot conflict with itself.
  """

  use LiveQuizWeb.ConnCase, async: true

  import LiveQuiz.GamesFixtures

  alias LiveQuiz.Games
  alias LiveQuizWeb.Api.ParticipantAuth

  describe "voltar para uma sala" do
    test "escolhe a credencial da sala do caminho, não a primeira apresentada", %{conn: conn} do
      target = game_session_fixture(%{status: :waiting})
      {participant, target_token} = credentialed_participant_fixture(target)

      other = game_session_fixture(%{status: :waiting})
      {elsewhere, other_token} = credentialed_participant_fixture(other)
      {:ok, _left} = Games.leave_game_session(elsewhere)

      # A credencial da outra sala vem primeiro: se a ordem decidisse, este
      # pedido seria sobre a sala errada. A outra participação foi abandonada,
      # então a exclusividade não tem o que recusar.
      conn =
        conn
        |> with_credential(other_token)
        |> with_credential(target_token)
        |> post(~p"/api/v1/game-sessions/#{target.join_code}/rejoin")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == participant.id
    end

    test "a ordem inversa leva à mesma sala", %{conn: conn} do
      target = game_session_fixture(%{status: :waiting})
      {participant, target_token} = credentialed_participant_fixture(target)

      other = game_session_fixture(%{status: :waiting})
      {elsewhere, other_token} = credentialed_participant_fixture(other)
      {:ok, _left} = Games.leave_game_session(elsewhere)

      conn =
        conn
        |> with_credential(target_token)
        |> with_credential(other_token)
        |> post(~p"/api/v1/game-sessions/#{target.join_code}/rejoin")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == participant.id
    end

    test "recusa a volta de quem está preso em outra sala", %{conn: conn} do
      target = game_session_fixture(%{status: :waiting})
      {participant, target_token} = credentialed_participant_fixture(target)
      {:ok, _left} = Games.leave_game_session(participant)

      other = game_session_fixture(%{status: :waiting})
      {_elsewhere, other_token} = credentialed_participant_fixture(other)

      # A participação abandonada aqui e uma ativa lá. Contando só com o token
      # desta sala, o contexto não enxergava a outra e deixava voltar.
      conn =
        conn
        |> with_credential(target_token)
        |> with_credential(other_token)
        |> post(~p"/api/v1/game-sessions/#{target.join_code}/rejoin")

      assert json_response(conn, 409)
    end

    test "deixa voltar quando as outras credenciais não prendem ninguém", %{conn: conn} do
      target = game_session_fixture(%{status: :waiting})
      {participant, target_token} = credentialed_participant_fixture(target)
      {:ok, _left} = Games.leave_game_session(participant)

      other = game_session_fixture(%{status: :waiting})
      {gone, other_token} = credentialed_participant_fixture(other)
      {:ok, _also_left} = Games.leave_game_session(gone)

      conn =
        conn
        |> with_credential(target_token)
        |> with_credential(other_token)
        |> post(~p"/api/v1/game-sessions/#{target.join_code}/rejoin")

      assert json_response(conn, 200)
    end

    test "uma credencial inválida no meio não atrapalha", %{conn: conn} do
      target = game_session_fixture(%{status: :waiting})
      {_participant, target_token} = credentialed_participant_fixture(target)

      conn =
        conn
        |> with_credential("nao-e-uma-credencial")
        |> with_credential(target_token)
        |> post(~p"/api/v1/game-sessions/#{target.join_code}/rejoin")

      assert json_response(conn, 200)
    end

    test "a credencial de outra sala sozinha não abre esta", %{conn: conn} do
      target = game_session_fixture(%{status: :waiting})
      other = game_session_fixture(%{status: :waiting})
      {_elsewhere, other_token} = credentialed_participant_fixture(other)

      conn =
        conn
        |> with_credential(other_token)
        |> post(~p"/api/v1/game-sessions/#{target.join_code}/rejoin")

      assert json_response(conn, 404)
    end
  end

  describe "o limite de credenciais apresentadas" do
    test "um cabeçalho por sala vira uma consulta por sala, e há um teto" do
      assert ParticipantAuth.max_credentials() == 10
    end

    test "as credenciais além do teto são descartadas, não recusadas", %{conn: conn} do
      target = game_session_fixture(%{status: :waiting})
      {_participant, target_token} = credentialed_participant_fixture(target)

      conn =
        Enum.reduce(1..ParticipantAuth.max_credentials(), conn, fn index, acc ->
          with_credential(acc, "credencial-de-enchimento-#{index}")
        end)

      # A credencial verdadeira vem depois do teto: é descartada junto com o
      # enchimento, e o pedido responde como se ela não tivesse sido enviada.
      conn =
        conn
        |> with_credential(target_token)
        |> post(~p"/api/v1/game-sessions/#{target.join_code}/rejoin")

      assert json_response(conn, 401)
    end
  end

  # `put_req_header/3` replaces; carrying an account and one or more
  # participations at the same time is exactly what repeated `Authorization`
  # headers are for here, so they are appended in order.
  defp with_credential(conn, token) do
    %{conn | req_headers: conn.req_headers ++ [{"authorization", "Participant " <> token}]}
  end
end
