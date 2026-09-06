defmodule LiveQuizWeb.Api.V1.ParticipantControllerTest do
  use LiveQuizWeb.ConnCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Accounts.User
  alias LiveQuiz.Games
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Games.ParticipantToken
  alias LiveQuiz.Games.Presence
  alias LiveQuiz.Repo

  @unauthorized %{"errors" => %{"detail" => "Não autenticado"}}
  @forbidden %{"errors" => %{"detail" => "Acesso negado"}}
  @not_found %{"errors" => %{"detail" => "Não encontrado"}}

  setup do
    host = user_fixture()
    session = game_session_fixture(%{host: host, status: :waiting})
    {participant, token} = credentialed_participant_fixture(session, %{nickname: "Ana"})

    %{
      host: host,
      host_scope: Scope.for_user(host),
      session: session,
      participant: participant,
      token: token
    }
  end

  describe "GET /api/v1/game-sessions/:code/participants" do
    test "quem tem a credencial da sala vê a lista", context do
      %{session: session, token: token, participant: participant} = context
      other = participant_fixture(session, %{nickname: "Bruno"})

      data = token |> credential() |> get(participants_path(session)) |> json_response(200)

      assert data == %{
               "data" => [
                 %{
                   "id" => participant.id,
                   "nickname" => "Ana",
                   "connected" => false,
                   "joined_at" => iso(participant.joined_at)
                 },
                 %{
                   "id" => other.id,
                   "nickname" => "Bruno",
                   "connected" => false,
                   "joined_at" => iso(other.joined_at)
                 }
               ]
             }
    end

    test "a lista carrega o estado de conexão de cada um", context do
      %{session: session, token: token, participant: participant} = context
      :ok = Games.subscribe(session.id)
      _absent = participant_fixture(session, %{nickname: "Bruno"})
      connect(participant)

      data = token |> credential() |> get(participants_path(session)) |> json_response(200)

      assert [%{"connected" => true}, %{"connected" => false}] = data["data"]
    end

    test "a lista nunca conta quem tem conta", context do
      %{session: session, token: token} = context
      _with_account = participant_fixture(session, %{user: user_fixture(), nickname: "Bruno"})

      data = token |> credential() |> get(participants_path(session)) |> json_response(200)

      for participant <- data["data"] do
        assert Enum.sort(Map.keys(participant)) == ~w(connected id joined_at nickname)
      end
    end

    test "o host vê a lista com o JWT", context do
      %{host: host, session: session, participant: participant} = context

      data = host |> jwt() |> get(participants_path(session)) |> json_response(200)

      assert [%{"id" => id}] = data["data"]
      assert id == participant.id
    end

    test "sem credencial nenhuma responde 401", %{session: session} do
      assert anonymous() |> get(participants_path(session)) |> json_response(401) == @unauthorized
    end

    test "a credencial de outra sala responde 403", %{session: session} do
      elsewhere = game_session_fixture(%{status: :waiting})
      {_participant, token} = credentialed_participant_fixture(elsewhere)

      assert token |> credential() |> get(participants_path(session)) |> json_response(403) ==
               @forbidden
    end

    test "um terceiro autenticado responde 403", %{session: session} do
      assert user_fixture() |> jwt() |> get(participants_path(session)) |> json_response(403) ==
               @forbidden
    end

    test "quem saiu deixa de enxergar a lista", context do
      %{participant: participant, session: session, token: token} = context
      {:ok, _participant} = Games.leave_game_session(participant)

      assert token |> credential() |> get(participants_path(session)) |> json_response(403) ==
               @forbidden
    end

    test "uma sala inexistente responde 404", %{token: token} do
      assert token
             |> credential()
             |> get(~p"/api/v1/game-sessions/ZZZZZZ/participants")
             |> json_response(404) == @not_found
    end

    test "uma sala encerrada responde 404", context do
      %{host_scope: host_scope, session: session, token: token} = context
      {:ok, _session} = Games.cancel_game_session(host_scope, session)

      assert token |> credential() |> get(participants_path(session)) |> json_response(404) ==
               @not_found
    end
  end

  describe "GET /api/v1/game-sessions/:code/me" do
    test "devolve a própria participação", context do
      %{session: session, participant: participant, token: token} = context

      data = token |> credential() |> get(me_path(session)) |> json_response(200)

      assert data == %{
               "data" => %{
                 "id" => participant.id,
                 "nickname" => "Ana",
                 "connected" => false,
                 "joined_at" => iso(participant.joined_at),
                 "user_id" => nil
               }
             }
    end

    test "conta a conexão de quem está com a sala aberta", context do
      %{session: session, participant: participant, token: token} = context
      :ok = Games.subscribe(session.id)
      connect(participant)

      data = token |> credential() |> get(me_path(session)) |> json_response(200)

      assert data["data"]["connected"] == true
    end

    test "mostra a conta de quem entrou autenticado", %{session: session} do
      user = user_fixture()
      {participant, token} = credentialed_participant_fixture(session, %{user: user})

      data = token |> credential() |> get(me_path(session)) |> json_response(200)

      assert data["data"]["user_id"] == user.id
      assert data["data"]["id"] == participant.id
    end

    test "continua respondendo a quem saiu, porque a vaga é sua", context do
      %{session: session, participant: participant, token: token} = context
      {:ok, _participant} = Games.leave_game_session(participant)

      data = token |> credential() |> get(me_path(session)) |> json_response(200)

      assert data["data"]["id"] == participant.id
    end

    test "a credencial de outra sala responde 404", %{session: session} do
      elsewhere = game_session_fixture(%{status: :waiting})
      {_participant, token} = credentialed_participant_fixture(elsewhere)

      assert token |> credential() |> get(me_path(session)) |> json_response(404) == @not_found
    end

    test "só o JWT não identifica uma participação", context do
      %{host: host, session: session} = context

      assert host |> jwt() |> get(me_path(session)) |> json_response(401) == @unauthorized
    end

    test "sem credencial nenhuma responde 401", %{session: session} do
      assert anonymous() |> get(me_path(session)) |> json_response(401) == @unauthorized
    end
  end

  describe "POST /api/v1/game-sessions/:code/rejoin" do
    test "devolve a mesma participação depois de sair", context do
      %{session: session, participant: participant, token: token} = context
      {:ok, _participant} = Games.leave_game_session(participant)

      data = token |> credential() |> post(rejoin_path(session)) |> json_response(200)

      assert data["data"]["id"] == participant.id
      assert data["data"]["nickname"] == "Ana"
      assert data["data"]["joined_at"] == iso(participant.joined_at)

      restored = Repo.get!(Participant, participant.id)
      refute restored.left_at
      refute restored.released_at
    end

    test "volta para uma sala já em andamento", context do
      %{session: session, participant: participant, token: token} = context
      {:ok, _participant} = Games.leave_game_session(participant)
      Repo.update!(Ecto.Changeset.change(session, status: :in_progress))

      data = token |> credential() |> post(rejoin_path(session)) |> json_response(200)

      assert data["data"]["id"] == participant.id
    end

    test "não toma um assento novo", context do
      %{session: session, token: token} = context

      assert token |> credential() |> post(rejoin_path(session)) |> json_response(200)
      assert Games.reserved_slots(session) == 1
    end

    test "uma sala cancelada responde 410", context do
      %{host_scope: host_scope, session: session, token: token} = context
      {:ok, _session} = Games.cancel_game_session(host_scope, session)

      assert token |> credential() |> post(rejoin_path(session)) |> json_response(410) == %{
               "errors" => %{"detail" => "Esta sala foi encerrada"}
             }
    end

    test "uma sala expirada responde 410", context do
      %{session: session, token: token} = context
      {:ok, _session} = Games.expire_game_session(session)

      assert token |> credential() |> post(rejoin_path(session)) |> json_response(410) == %{
               "errors" => %{"detail" => "Esta sala foi encerrada"}
             }
    end

    test "quem está preso a outra sala responde 409", %{session: session} do
      user = user_fixture()
      {participant, token} = credentialed_participant_fixture(session, %{user: user})
      {:ok, _participant} = Games.leave_game_session(participant)

      elsewhere = game_session_fixture(%{status: :waiting})
      _elsewhere = participant_fixture(elsewhere, %{user: user})

      assert token |> credential() |> post(rejoin_path(session)) |> json_response(409) == %{
               "errors" => %{"detail" => "Você já está participando de outra sala"}
             }
    end

    test "o código de outra sala responde 404", %{token: token} do
      elsewhere = game_session_fixture(%{status: :waiting})

      assert token |> credential() |> post(rejoin_path(elsewhere)) |> json_response(404) ==
               @not_found
    end

    test "sem credencial responde 401", %{session: session} do
      assert anonymous() |> post(rejoin_path(session)) |> json_response(401) == @unauthorized
    end
  end

  describe "DELETE /api/v1/game-sessions/:code/leave" do
    test "sai da sala e some da lista", context do
      %{host: host, session: session, participant: participant, token: token} = context
      _other = participant_fixture(session, %{nickname: "Bruno"})

      assert token |> credential() |> delete(leave_path(session)) |> response(204) == ""

      left = Repo.get!(Participant, participant.id)
      assert left.left_at
      assert left.released_at

      data = host |> jwt() |> get(participants_path(session)) |> json_response(200)
      assert Enum.map(data["data"], & &1["nickname"]) == ["Bruno"]
    end

    test "sair duas vezes continua respondendo 204", %{session: session, token: token} do
      assert token |> credential() |> delete(leave_path(session)) |> response(204) == ""
      assert token |> credential() |> delete(leave_path(session)) |> response(204) == ""
    end

    test "não devolve o assento", %{session: session, token: token} do
      assert token |> credential() |> delete(leave_path(session)) |> response(204) == ""
      assert Games.reserved_slots(session) == 1
    end

    test "libera a pessoa para entrar em outra sala", %{session: session} do
      user = user_fixture()
      {_participant, token} = credentialed_participant_fixture(session, %{user: user})
      elsewhere = game_session_fixture(%{status: :waiting})

      assert token |> credential() |> delete(leave_path(session)) |> response(204) == ""

      assert {:ok, %Participant{}, _token} =
               Games.join_game_session(Scope.for_user(user), elsewhere.join_code, %{
                 "nickname" => "Ana"
               })
    end

    test "o código de outra sala responde 404", %{token: token} do
      elsewhere = game_session_fixture(%{status: :waiting})

      assert token |> credential() |> delete(leave_path(elsewhere)) |> json_response(404) ==
               @not_found
    end

    test "sem credencial responde 401", %{session: session} do
      assert anonymous() |> delete(leave_path(session)) |> json_response(401) == @unauthorized
    end

    test "uma credencial desconhecida responde 401", %{session: session} do
      {unknown, _hash} = ParticipantToken.build()

      assert unknown |> credential() |> delete(leave_path(session)) |> json_response(401) ==
               @unauthorized
    end
  end

  describe "a credencial não aparece em resposta nenhuma" do
    test "nem na lista, nem em /me, nem ao voltar", context do
      %{host: host, session: session, token: token} = context

      responses = [
        get(credential(token), participants_path(session)),
        get(credential(token), me_path(session)),
        post(credential(token), rejoin_path(session)),
        get(jwt(host), participants_path(session))
      ]

      for response <- responses do
        assert response.status == 200
        refute response.resp_body =~ token
        refute response.resp_body =~ "participant_token"
        refute response.resp_body =~ "access_token_hash"
      end
    end
  end

  defp anonymous, do: put_req_header(build_conn(), "accept", "application/json")

  defp credential(token), do: put_api_participant(anonymous(), token)

  defp jwt(%User{} = user), do: log_in_api_user(anonymous(), user)

  defp participants_path(session), do: ~p"/api/v1/game-sessions/#{session.join_code}/participants"
  defp me_path(session), do: ~p"/api/v1/game-sessions/#{session.join_code}/me"
  defp rejoin_path(session), do: ~p"/api/v1/game-sessions/#{session.join_code}/rejoin"
  defp leave_path(session), do: ~p"/api/v1/game-sessions/#{session.join_code}/leave"

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp connect(%Participant{} = participant) do
    {:ok, connection} = Agent.start(fn -> :connected end)
    on_exit(fn -> Process.exit(connection, :kill) end)

    {:ok, _ref} = Presence.track_participant(connection, participant, Ecto.UUID.generate())
    assert_receive {:presence_changed, _session_id}, 2_000

    connection
  end
end
