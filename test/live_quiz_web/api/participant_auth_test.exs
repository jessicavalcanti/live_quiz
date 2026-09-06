defmodule LiveQuizWeb.Api.ParticipantAuthTest do
  use LiveQuizWeb.ConnCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Accounts.User
  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Games.ParticipantToken
  alias LiveQuiz.Repo
  alias LiveQuizWeb.Api.ParticipantAuth

  @unauthorized %{"errors" => %{"detail" => "Não autenticado"}}

  defp call(conn, opts \\ []) do
    ParticipantAuth.call(conn, ParticipantAuth.init(opts))
  end

  defp authorization(conn, value) do
    Plug.Conn.prepend_req_headers(conn, [{"authorization", value}])
  end

  setup do
    session = game_session_fixture(%{status: :waiting})
    {participant, token} = credentialed_participant_fixture(session)

    %{session: session, participant: participant, token: token}
  end

  describe "credencial de participação" do
    test "resolve a participação do esquema Participant", context do
      %{conn: conn, participant: participant, token: token} = context

      conn = conn |> put_api_participant(token) |> call()

      refute conn.halted
      assert %Participant{} = resolved = conn.assigns.current_participant
      assert resolved.id == participant.id
      assert conn.assigns.participant_token == token
      refute conn.assigns[:current_scope]
    end

    test "aceita o esquema em qualquer caixa", %{
      conn: conn,
      participant: participant,
      token: token
    } do
      conn = conn |> authorization("participant #{token}") |> call()

      refute conn.halted
      assert conn.assigns.current_participant.id == participant.id
    end

    test "resolve a credencial de uma sala já encerrada", context do
      %{conn: conn, session: session, participant: participant, token: token} = context
      {:ok, _session} = Games.cancel_game_session(host_scope(session), session)

      conn = conn |> put_api_participant(token) |> call()

      refute conn.halted
      assert conn.assigns.current_participant.id == participant.id
    end

    test "resolve a credencial de quem saiu da sala", context do
      %{conn: conn, participant: participant, token: token} = context
      {:ok, _participant} = Games.leave_game_session(participant)

      conn = conn |> put_api_participant(token) |> call()

      refute conn.halted
      assert conn.assigns.current_participant.id == participant.id
    end
  end

  describe "recusas" do
    test "sem header de autorização responde 401", %{conn: conn} do
      conn = call(conn)

      assert conn.halted
      assert json_response(conn, 401) == @unauthorized
    end

    test "um Bearer não é lido como credencial de participação", context do
      %{conn: conn, token: token} = context

      conn = conn |> authorization("Bearer #{token}") |> call()

      assert conn.halted
      assert json_response(conn, 401) == @unauthorized
    end

    test "um esquema desconhecido responde 401", %{conn: conn, token: token} do
      conn = conn |> authorization("Token #{token}") |> call()

      assert conn.halted
      assert json_response(conn, 401) == @unauthorized
    end

    test "um header sem esquema responde 401", %{conn: conn, token: token} do
      conn = conn |> authorization(token) |> call()

      assert conn.halted
      assert json_response(conn, 401) == @unauthorized
    end

    test "um token malformado responde 401", %{conn: conn} do
      conn = conn |> put_api_participant("nao-e-base64!") |> call()

      assert conn.halted
      assert json_response(conn, 401) == @unauthorized
    end

    test "um token inexistente responde 401", %{conn: conn} do
      {unknown, _hash} = ParticipantToken.build()

      conn = conn |> put_api_participant(unknown) |> call()

      assert conn.halted
      assert json_response(conn, 401) == @unauthorized
    end
  end

  describe "credencial de conta" do
    test "resolve o escopo do JWT", %{conn: conn} do
      user = user_fixture()

      conn = conn |> log_in_api_user(user) |> call()

      refute conn.halted
      assert conn.assigns.current_scope.user.id == user.id
      refute conn.assigns[:current_participant]
    end

    test "um JWT expirado responde 401", %{conn: conn} do
      user = user_fixture()

      conn = conn |> log_in_api_user(user, ttl: {-1, :minute}) |> call()

      assert conn.halted
      assert json_response(conn, 401) == @unauthorized
    end

    test "um refresh token não vale como credencial", %{conn: conn} do
      user = user_fixture()

      conn = conn |> log_in_api_user(user, token_type: "refresh") |> call()

      assert conn.halted
      assert json_response(conn, 401) == @unauthorized
    end

    test "as duas credenciais juntas identificam a pessoa como ambas", context do
      %{conn: conn, participant: participant, token: token} = context
      user = user_fixture()

      conn = conn |> log_in_api_user(user) |> put_api_participant(token) |> call()

      refute conn.halted
      assert conn.assigns.current_scope.user.id == user.id
      assert conn.assigns.current_participant.id == participant.id
    end
  end

  describe "require: false" do
    test "deixa passar quem não apresenta nada", %{conn: conn} do
      conn = call(conn, require: false)

      refute conn.halted
      refute conn.assigns[:current_participant]
      refute conn.assigns[:current_scope]
    end

    test "ignora um token que não compra nada, porque ali ele é só uma pista", %{conn: conn} do
      {unknown, _hash} = ParticipantToken.build()

      conn = conn |> put_api_participant(unknown) |> call(require: false)

      refute conn.halted
      refute conn.assigns[:current_participant]
    end

    test "ainda resolve a credencial apresentada", %{
      conn: conn,
      participant: participant,
      token: token
    } do
      conn = conn |> put_api_participant(token) |> call(require: false)

      refute conn.halted
      assert conn.assigns.current_participant.id == participant.id
    end

    test "ainda recusa um JWT inválido", %{conn: conn} do
      user = user_fixture()

      conn = conn |> log_in_api_user(user, ttl: {-1, :minute}) |> call(require: false)

      assert conn.halted
      assert json_response(conn, 401) == @unauthorized
    end
  end

  describe "presented_tokens/1" do
    test "lista as credenciais de participação apresentadas", %{conn: conn, token: token} do
      {other, _hash} = ParticipantToken.build()

      conn =
        conn
        |> put_api_participant(other)
        |> put_api_participant(token)

      assert ParticipantAuth.presented_tokens(conn) == [token, other]
    end

    test "não confunde um Bearer com uma credencial", %{conn: conn} do
      conn = log_in_api_user(conn, user_fixture())

      assert ParticipantAuth.presented_tokens(conn) == []
    end

    test "não lista nada quando não há header", %{conn: conn} do
      assert ParticipantAuth.presented_tokens(conn) == []
    end
  end

  defp host_scope(%GameSession{host_id: host_id}) do
    Scope.for_user(Repo.get!(User, host_id))
  end
end
