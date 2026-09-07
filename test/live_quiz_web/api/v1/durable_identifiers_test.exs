defmodule LiveQuizWeb.Api.V1.DurableIdentifiersTest do
  @moduledoc """
  Which address survives the room it names, and which header carries the
  credential.

  Regressions for R28 and R29 of the review. A join code is short because it is
  read out loud, and reusable because a room ends — which makes it a fine way in
  and a poor way back. And two credentials sharing `Authorization` looked
  workable only because Plug represents that field as a list.
  """

  use LiveQuizWeb.ConnCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import LiveQuiz.QuizzesFixtures

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuizWeb.Api.ParticipantAuth

  describe "o identificador durável de uma partida" do
    test "é emitido na criação e nunca vem do pedido" do
      session = game_session_fixture(%{status: :waiting})

      assert {:ok, _uuid} = Ecto.UUID.cast(session.public_id)
    end

    test "duas salas com o mesmo código têm identificadores diferentes", %{conn: _conn} do
      first = game_session_fixture(%{status: :waiting})
      {:ok, _cancelled} = cancel(first)

      # O código volta a circular quando a sala termina: é a mesma cadeia de
      # seis caracteres nomeando outra partida.
      second = game_session_fixture(%{status: :waiting, join_code: first.join_code})

      assert second.join_code == first.join_code
      refute second.public_id == first.public_id
    end

    test "resolve a partida certa mesmo com o código reaproveitado" do
      first = game_session_fixture(%{status: :waiting})
      {:ok, _cancelled} = cancel(first)
      second = game_session_fixture(%{status: :waiting, join_code: first.join_code})

      # Pelo código, o endereço antigo passa a responder sobre a sala nova.
      assert {:ok, %GameSession{id: id}} = Games.get_match_by_code(first.join_code)
      assert id == second.id

      # Pelo identificador durável, continua sendo sobre a partida de origem.
      assert {:ok, %GameSession{id: ^id}} = Games.get_match_by_reference(second.public_id)
      assert {:ok, %GameSession{id: original}} = Games.get_match_by_reference(first.public_id)
      assert original == first.id
    end

    test "um identificador que não existe é ausência, não erro" do
      assert Games.get_match_by_public_id(Ecto.UUID.generate()) == {:error, :not_found}
      assert Games.get_match_by_public_id("nao-e-um-uuid") == {:error, :not_found}
      assert Games.get_match_by_reference("nao-e-nada") == {:error, :not_found}
    end
  end

  describe "o resultado de uma partida encerrada" do
    setup :host_with_finished_match

    test "responde pelo identificador durável", %{conn: conn, session: session} do
      body =
        conn
        |> get(~p"/api/v1/game-sessions/#{session.public_id}/results")
        |> json_response(200)

      assert body["data"]["session"]["public_id"] == session.public_id
      assert body["data"]["session"]["code"] == session.join_code
    end

    test "continua respondendo pelo código, para endereços antigos", %{
      conn: conn,
      session: session
    } do
      body =
        conn
        |> get(~p"/api/v1/game-sessions/#{session.join_code}/results")
        |> json_response(200)

      assert body["data"]["session"]["public_id"] == session.public_id
    end

    test "o identificador durável não segue o código para a sala nova", %{
      conn: conn,
      scope: scope,
      session: session
    } do
      # O código volta a circular numa sala do mesmo host.
      reused =
        game_session_fixture(%{host: scope.user, status: :waiting, join_code: session.join_code})

      # Pelo código, o endereço antigo agora aponta para a sala nova — que não
      # terminou, e portanto não tem resultado.
      assert conn
             |> get(~p"/api/v1/game-sessions/#{session.join_code}/results")
             |> json_response(404)

      # Pelo identificador durável, o resultado da partida de origem continua lá.
      body =
        conn
        |> get(~p"/api/v1/game-sessions/#{session.public_id}/results")
        |> json_response(200)

      assert body["data"]["session"]["public_id"] == session.public_id
      refute body["data"]["session"]["public_id"] == reused.public_id
    end
  end

  describe "o transporte da credencial de participação" do
    test "o cabeçalho próprio identifica a participação", %{conn: conn} do
      session = game_session_fixture(%{status: :waiting})
      {participant, token} = credentialed_participant_fixture(session)

      conn =
        conn
        |> put_req_header(ParticipantAuth.participant_header(), token)
        |> post(~p"/api/v1/game-sessions/#{session.join_code}/rejoin")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == participant.id
    end

    test "vários cabeçalhos carregam várias salas", %{conn: conn} do
      target = game_session_fixture(%{status: :waiting})
      {participant, target_token} = credentialed_participant_fixture(target)

      other = game_session_fixture(%{status: :waiting})
      {gone, other_token} = credentialed_participant_fixture(other)
      {:ok, _left} = Games.leave_game_session(gone)

      conn =
        conn
        |> append_header(ParticipantAuth.participant_header(), other_token)
        |> append_header(ParticipantAuth.participant_header(), target_token)
        |> post(~p"/api/v1/game-sessions/#{target.join_code}/rejoin")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == participant.id
    end

    test "o transporte antigo continua funcionando", %{conn: conn} do
      session = game_session_fixture(%{status: :waiting})
      {participant, token} = credentialed_participant_fixture(session)

      conn =
        conn
        |> append_header("authorization", "Participant " <> token)
        |> post(~p"/api/v1/game-sessions/#{session.join_code}/rejoin")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == participant.id
    end

    test "o cabeçalho próprio tem precedência sobre o antigo", %{conn: conn} do
      target = game_session_fixture(%{status: :waiting})
      {participant, target_token} = credentialed_participant_fixture(target)

      other = game_session_fixture(%{status: :waiting})
      {_elsewhere, other_token} = credentialed_participant_fixture(other)

      # Quem manda os dois já escolheu: o antigo nem é consultado.
      conn =
        conn
        |> append_header("authorization", "Participant " <> other_token)
        |> put_req_header(ParticipantAuth.participant_header(), target_token)
        |> post(~p"/api/v1/game-sessions/#{target.join_code}/rejoin")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == participant.id
    end

    test "um cabeçalho em branco não conta como credencial", %{conn: conn} do
      session = game_session_fixture(%{status: :waiting})

      conn =
        conn
        |> put_req_header(ParticipantAuth.participant_header(), "   ")
        |> post(~p"/api/v1/game-sessions/#{session.join_code}/rejoin")

      assert json_response(conn, 401)
    end
  end

  defp host_with_finished_match(%{conn: conn}) do
    user = user_fixture()
    scope = Scope.for_user(user)
    {:ok, token, _claims} = LiveQuiz.Accounts.Guardian.encode_and_sign(user)

    quiz = quiz_fixture(scope)
    question_fixture(scope, quiz)
    session = game_session_fixture(%{host: user, quiz: quiz, status: :in_progress})
    snapshot_fixture(session, count: 1)

    {:ok, opened} = Games.advance_question(scope, session, nil)
    Games.QuestionTimer.stop(opened.id)
    {:ok, _finished} = Games.finish_game_session(scope, opened)

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> token),
      scope: scope,
      session: LiveQuiz.Repo.get!(GameSession, session.id)
    }
  end

  defp cancel(%GameSession{host_id: host_id} = session) do
    scope = Scope.for_user(LiveQuiz.Repo.get!(LiveQuiz.Accounts.User, host_id))

    Games.cancel_game_session(scope, session)
  end

  defp append_header(conn, name, value) do
    %{conn | req_headers: conn.req_headers ++ [{name, value}]}
  end
end
