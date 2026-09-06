defmodule LiveQuizWeb.Api.V1.GameSessionControllerTest do
  use LiveQuizWeb.ConnCase, async: true

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import LiveQuiz.QuizzesFixtures
  import Phoenix.LiveViewTest

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Games.ParticipantToken
  alias LiveQuiz.Games.Presence
  alias LiveQuiz.Repo

  @unauthorized %{"errors" => %{"detail" => "Não autenticado"}}
  @not_found %{"errors" => %{"detail" => "Não encontrado"}}

  @room_keys ~w(
    code connected_count expires_at finished_at inserted_at max_participants
    quiz_id quiz_title reserved_slots started_at status
  )

  setup :register_and_log_in_api_user

  setup %{conn: conn} do
    %{conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "POST /api/v1/game-sessions" do
    test "abre a sala do quiz e devolve o código", %{conn: conn, scope: scope} do
      quiz = playable_quiz(scope, %{title: "Geografia"})

      data =
        conn |> post(~p"/api/v1/game-sessions", %{"quiz_id" => quiz.id}) |> json_response(201)

      assert %{
               "code" => code,
               "status" => "waiting",
               "quiz_title" => "Geografia",
               "reserved_slots" => 0,
               "max_participants" => 25,
               "connected_count" => 0,
               "started_at" => nil,
               "finished_at" => nil,
               "expires_at" => nil
             } = data["data"]

      assert data["data"]["quiz_id"] == quiz.id
      assert Enum.sort(Map.keys(data["data"])) == @room_keys
      assert Repo.get_by!(GameSession, join_code: code).host_id == scope.user.id
    end

    test "as datas saem em ISO 8601 UTC", %{conn: conn, scope: scope} do
      quiz = playable_quiz(scope)

      data =
        conn |> post(~p"/api/v1/game-sessions", %{"quiz_id" => quiz.id}) |> json_response(201)

      assert {:ok, _at, 0} = DateTime.from_iso8601(data["data"]["inserted_at"])
      assert String.ends_with?(data["data"]["inserted_at"], "Z")
    end

    test "um quiz sem perguntas responde 422", %{conn: conn, scope: scope} do
      quiz = quiz_fixture(scope)

      conn = post(conn, ~p"/api/v1/game-sessions", %{"quiz_id" => quiz.id})

      assert json_response(conn, 422) == %{
               "errors" => %{"detail" => "O quiz precisa ter ao menos uma pergunta"}
             }
    end

    test "quem já tem uma sala aberta responde 409", %{conn: conn, scope: scope} do
      quiz = playable_quiz(scope)
      _open = game_session_fixture(%{host: scope.user, quiz: quiz, status: :waiting})

      conn = post(conn, ~p"/api/v1/game-sessions", %{"quiz_id" => quiz.id})

      assert json_response(conn, 409) == %{
               "errors" => %{"detail" => "Você já possui uma sala ativa"}
             }
    end

    test "quem está participando de outra sala responde 409", %{conn: conn, scope: scope} do
      quiz = playable_quiz(scope)
      elsewhere = game_session_fixture(%{status: :waiting})
      _participant = participant_fixture(elsewhere, %{user: scope.user})

      conn = post(conn, ~p"/api/v1/game-sessions", %{"quiz_id" => quiz.id})

      assert json_response(conn, 409) == %{
               "errors" => %{"detail" => "Saia da sala em que você está para abrir uma nova"}
             }
    end

    test "um quiz de outro dono responde 404", %{conn: conn} do
      quiz = playable_quiz(user_scope_fixture())

      conn = post(conn, ~p"/api/v1/game-sessions", %{"quiz_id" => quiz.id})

      assert json_response(conn, 404) == @not_found
      refute Repo.exists?(GameSession)
    end

    test "um quiz inexistente, um id que não é id e um corpo vazio respondem 404", context do
      %{conn: conn} = context

      for body <- [%{"quiz_id" => 0}, %{"quiz_id" => "abc"}, %{"quiz_id" => nil}, %{}] do
        response = conn |> post(~p"/api/v1/game-sessions", body) |> json_response(404)

        assert response == @not_found
      end
    end

    test "sem token responde 401", %{scope: scope} do
      quiz = playable_quiz(scope)

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> post(~p"/api/v1/game-sessions", %{"quiz_id" => quiz.id})

      assert json_response(conn, 401) == @unauthorized
      refute Repo.exists?(GameSession)
    end
  end

  describe "GET /api/v1/game-sessions/:code" do
    test "responde a quem não tem identidade nenhuma", %{conn: conn} do
      session = game_session_fixture(%{quiz_title: "Geografia", status: :waiting})

      data =
        anonymous() |> get(~p"/api/v1/game-sessions/#{session.join_code}") |> json_response(200)

      assert data == %{
               "data" => %{
                 "code" => session.join_code,
                 "quiz_title" => "Geografia",
                 "status" => "waiting",
                 "available" => true
               }
             }

      assert conn |> get(~p"/api/v1/game-sessions/#{session.join_code}") |> json_response(200) ==
               data
    end

    test "não vaza participantes nem contagem", %{conn: _conn} do
      session = game_session_fixture(%{status: :waiting})
      for _index <- 1..3, do: participant_fixture(session)

      data =
        anonymous() |> get(~p"/api/v1/game-sessions/#{session.join_code}") |> json_response(200)

      assert Enum.sort(Map.keys(data["data"])) == ~w(available code quiz_title status)

      for leaked <- ~w(participants reserved_slots connected_count participants_count) do
        refute Map.has_key?(data["data"], leaked)
      end
    end

    test "uma sala lotada não está disponível" do
      session = game_session_fixture(%{status: :waiting})
      for _index <- 1..25, do: participant_fixture(session)

      data =
        anonymous() |> get(~p"/api/v1/game-sessions/#{session.join_code}") |> json_response(200)

      assert data["data"]["available"] == false
    end

    test "uma sala em andamento não está disponível" do
      session = game_session_fixture(%{status: :in_progress})

      data =
        anonymous() |> get(~p"/api/v1/game-sessions/#{session.join_code}") |> json_response(200)

      assert data["data"] == %{
               "code" => session.join_code,
               "quiz_title" => session.quiz_title,
               "status" => "in_progress",
               "available" => false
             }
    end

    test "o código é aceito em minúsculas" do
      session = game_session_fixture(%{status: :waiting})
      code = String.downcase(session.join_code)

      data = anonymous() |> get(~p"/api/v1/game-sessions/#{code}") |> json_response(200)

      assert data["data"]["code"] == session.join_code
    end

    test "uma sala encerrada, um código inexistente e um código inválido respondem 404" do
      cancelled = game_session_fixture(%{status: :cancelled})

      for code <- [cancelled.join_code, "ZZZZZZ", "abc", "0OI111"] do
        assert anonymous() |> get(~p"/api/v1/game-sessions/#{code}") |> json_response(404) ==
                 @not_found
      end
    end
  end

  describe "GET /api/v1/game-sessions/:code/host" do
    test "devolve a sala inteira com os participantes", %{conn: conn, scope: scope} do
      session = game_session_fixture(%{host: scope.user, status: :waiting})
      first = participant_fixture(session, %{nickname: "Ana"})
      second = participant_fixture(session, %{nickname: "Bruno"})

      data =
        conn |> get(~p"/api/v1/game-sessions/#{session.join_code}/host") |> json_response(200)

      assert Enum.sort(Map.keys(data["data"])) == Enum.sort(["participants" | @room_keys])
      assert data["data"]["reserved_slots"] == 2
      assert data["data"]["connected_count"] == 0

      assert data["data"]["participants"] == [
               %{
                 "id" => first.id,
                 "nickname" => "Ana",
                 "connected" => false,
                 "joined_at" => iso(first.joined_at)
               },
               %{
                 "id" => second.id,
                 "nickname" => "Bruno",
                 "connected" => false,
                 "joined_at" => iso(second.joined_at)
               }
             ]
    end

    test "a lista carrega o estado de conexão de cada um", %{conn: conn, scope: scope} do
      session = game_session_fixture(%{host: scope.user, status: :waiting})
      :ok = Games.subscribe(session.id)
      present = participant_fixture(session, %{nickname: "Ana"})
      _absent = participant_fixture(session, %{nickname: "Bruno"})
      connect(present)

      data =
        conn |> get(~p"/api/v1/game-sessions/#{session.join_code}/host") |> json_response(200)

      assert data["data"]["connected_count"] == 1
      assert [%{"connected" => true}, %{"connected" => false}] = data["data"]["participants"]
    end

    test "a sala continua respondendo depois de encerrada", %{conn: conn, scope: scope} do
      session = game_session_fixture(%{host: scope.user, status: :cancelled})

      data =
        conn |> get(~p"/api/v1/game-sessions/#{session.join_code}/host") |> json_response(200)

      assert data["data"]["status"] == "cancelled"
    end

    test "a sala de outro host responde 404, não 403", %{conn: conn} do
      session = game_session_fixture(%{status: :waiting})

      conn = get(conn, ~p"/api/v1/game-sessions/#{session.join_code}/host")

      assert json_response(conn, 404) == @not_found
    end

    test "um código inexistente responde 404", %{conn: conn} do
      assert conn |> get(~p"/api/v1/game-sessions/ZZZZZZ/host") |> json_response(404) ==
               @not_found
    end

    test "sem token responde 401" do
      session = game_session_fixture(%{status: :waiting})

      conn = get(anonymous(), ~p"/api/v1/game-sessions/#{session.join_code}/host")

      assert json_response(conn, 401) == @unauthorized
    end
  end

  describe "POST /api/v1/game-sessions/:code/join" do
    setup do
      %{session: game_session_fixture(%{status: :waiting})}
    end

    test "quem não tem conta entra e recebe a credencial", %{session: session} do
      conn =
        post(anonymous(), ~p"/api/v1/game-sessions/#{session.join_code}/join", %{
          "nickname" => "Ana"
        })

      assert %{"data" => %{"participant" => participant, "participant_token" => token}} =
               json_response(conn, 201)

      assert Enum.sort(Map.keys(participant)) == ~w(connected id joined_at nickname user_id)
      assert participant["nickname"] == "Ana"
      assert participant["connected"] == false
      assert participant["user_id"] == nil
      assert {:ok, _at, 0} = DateTime.from_iso8601(participant["joined_at"])

      assert {:ok, %Participant{} = found} = Games.get_participant_by_token(token)
      assert found.id == participant["id"]
      assert found.game_session_id == session.id
    end

    test "quem manda o JWT tem a participação ligada à conta", context do
      %{conn: conn, session: session, user: user} = context

      conn =
        post(conn, ~p"/api/v1/game-sessions/#{session.join_code}/join", %{"nickname" => "Ana"})

      assert %{"data" => %{"participant" => participant}} = json_response(conn, 201)
      assert participant["user_id"] == user.id
      assert Repo.get!(Participant, participant["id"]).user_id == user.id
    end

    test "entrar de novo na mesma sala devolve a mesma participação", %{session: session} do
      first =
        anonymous()
        |> post(~p"/api/v1/game-sessions/#{session.join_code}/join", %{"nickname" => "Ana"})
        |> json_response(201)

      token = first["data"]["participant_token"]

      second =
        anonymous()
        |> put_api_participant(token)
        |> post(~p"/api/v1/game-sessions/#{session.join_code}/join", %{"nickname" => "Ana"})
        |> json_response(201)

      assert second["data"]["participant"]["id"] == first["data"]["participant"]["id"]
      assert Games.reserved_slots(session) == 1
    end

    test "um apelido já tomado responde 409, sem olhar a caixa", %{session: session} do
      _taken = participant_fixture(session, %{nickname: "Ana"})

      conn =
        post(anonymous(), ~p"/api/v1/game-sessions/#{session.join_code}/join", %{
          "nickname" => "ana"
        })

      assert json_response(conn, 409) == %{
               "errors" => %{"detail" => "Este apelido já está em uso nesta sala"}
             }
    end

    test "um apelido inválido responde 422 com o erro no campo", %{session: session} do
      conn =
        post(anonymous(), ~p"/api/v1/game-sessions/#{session.join_code}/join", %{
          "nickname" => "A"
        })

      assert %{"errors" => %{"nickname" => [message]}} = json_response(conn, 422)
      assert message =~ "2"
    end

    test "um corpo sem apelido responde 422", %{session: session} do
      conn = post(anonymous(), ~p"/api/v1/game-sessions/#{session.join_code}/join", %{})

      assert %{"errors" => %{"nickname" => ["não pode ficar em branco"]}} =
               json_response(conn, 422)
    end

    test "uma sala lotada responde 409", %{session: session} do
      for _index <- 1..25, do: participant_fixture(session)

      conn =
        post(anonymous(), ~p"/api/v1/game-sessions/#{session.join_code}/join", %{
          "nickname" => "Ana"
        })

      assert json_response(conn, 409) == %{"errors" => %{"detail" => "Sala lotada"}}
    end

    test "uma partida já começada responde 409" do
      session = game_session_fixture(%{status: :in_progress})

      conn =
        post(anonymous(), ~p"/api/v1/game-sessions/#{session.join_code}/join", %{
          "nickname" => "Ana"
        })

      assert json_response(conn, 409) == %{"errors" => %{"detail" => "Esta partida já começou"}}
    end

    test "quem já está em outra sala pela conta responde 409", context do
      %{conn: conn, session: session, user: user} = context
      elsewhere = game_session_fixture(%{status: :waiting})
      _participant = participant_fixture(elsewhere, %{user: user})

      conn =
        post(conn, ~p"/api/v1/game-sessions/#{session.join_code}/join", %{"nickname" => "Ana"})

      assert json_response(conn, 409) == %{
               "errors" => %{"detail" => "Você já está participando de outra sala"}
             }
    end

    test "quem já está em outra sala pela credencial responde 409", %{session: session} do
      elsewhere = game_session_fixture(%{status: :waiting})
      {_participant, token} = credentialed_participant_fixture(elsewhere)

      conn =
        anonymous()
        |> put_api_participant(token)
        |> post(~p"/api/v1/game-sessions/#{session.join_code}/join", %{"nickname" => "Ana"})

      assert json_response(conn, 409) == %{
               "errors" => %{"detail" => "Você já está participando de outra sala"}
             }
    end

    test "uma sala inexistente responde 404" do
      conn = post(anonymous(), ~p"/api/v1/game-sessions/ZZZZZZ/join", %{"nickname" => "Ana"})

      assert json_response(conn, 404) == @not_found
    end

    test "um JWT expirado responde 401, mesmo entrando sendo público", %{session: session} do
      conn =
        anonymous()
        |> log_in_api_user(user_fixture(), ttl: {-1, :minute})
        |> post(~p"/api/v1/game-sessions/#{session.join_code}/join", %{"nickname" => "Ana"})

      assert json_response(conn, 401) == @unauthorized
    end
  end

  describe "POST /api/v1/game-sessions/:code/start" do
    setup %{scope: scope} do
      session = game_session_fixture(%{host: scope.user, status: :waiting})
      :ok = Games.subscribe(session.id)

      %{session: session}
    end

    test "põe a sala no ar com alguém conectado", %{conn: conn, session: session} do
      session |> participant_fixture() |> connect()

      data =
        conn |> post(~p"/api/v1/game-sessions/#{session.join_code}/start") |> json_response(200)

      assert data["data"]["status"] == "in_progress"
      assert data["data"]["connected_count"] == 1
      assert {:ok, _at, 0} = DateTime.from_iso8601(data["data"]["started_at"])
      assert Repo.get!(GameSession, session.id).status == :in_progress
    end

    test "sem ninguém conectado responde 409", %{conn: conn, session: session} do
      _signed_up = participant_fixture(session)

      conn = post(conn, ~p"/api/v1/game-sessions/#{session.join_code}/start")

      assert json_response(conn, 409) == %{
               "errors" => %{"detail" => "É preciso ao menos um participante conectado"}
             }

      assert Repo.get!(GameSession, session.id).status == :waiting
    end

    test "a contagem enviada pelo cliente é ignorada", %{conn: conn, session: session} do
      _signed_up = participant_fixture(session)

      conn =
        post(conn, ~p"/api/v1/game-sessions/#{session.join_code}/start", %{
          "connected_count" => 99
        })

      assert json_response(conn, 409) == %{
               "errors" => %{"detail" => "É preciso ao menos um participante conectado"}
             }
    end

    test "iniciar duas vezes responde 409 na segunda", %{conn: conn, session: session} do
      session |> participant_fixture() |> connect()

      assert conn
             |> post(~p"/api/v1/game-sessions/#{session.join_code}/start")
             |> json_response(200)

      conn = post(conn, ~p"/api/v1/game-sessions/#{session.join_code}/start")

      assert json_response(conn, 409) == %{
               "errors" => %{"detail" => "Esta sala já foi encerrada"}
             }
    end

    test "uma sala encerrada responde 409", %{conn: conn, scope: scope} do
      cancelled = game_session_fixture(%{host: scope.user, status: :cancelled})

      conn = post(conn, ~p"/api/v1/game-sessions/#{cancelled.join_code}/start")

      assert json_response(conn, 409) == %{
               "errors" => %{"detail" => "Esta sala já foi encerrada"}
             }
    end

    test "a sala de outro host responde 404", %{conn: conn} do
      other = game_session_fixture(%{status: :waiting})

      conn = post(conn, ~p"/api/v1/game-sessions/#{other.join_code}/start")

      assert json_response(conn, 404) == @not_found
      assert Repo.get!(GameSession, other.id).status == :waiting
    end

    test "um participante nunca inicia a sala", %{session: session} do
      {_participant, token} = credentialed_participant_fixture(session)

      conn =
        anonymous()
        |> put_api_participant(token)
        |> post(~p"/api/v1/game-sessions/#{session.join_code}/start")

      assert json_response(conn, 401) == @unauthorized
      assert Repo.get!(GameSession, session.id).status == :waiting
    end
  end

  describe "POST /api/v1/game-sessions/:code/cancel" do
    test "encerra a sala do host", %{conn: conn, scope: scope} do
      session = game_session_fixture(%{host: scope.user, status: :waiting})

      data =
        conn |> post(~p"/api/v1/game-sessions/#{session.join_code}/cancel") |> json_response(200)

      assert data["data"]["status"] == "cancelled"
      assert {:ok, _at, 0} = DateTime.from_iso8601(data["data"]["finished_at"])
      assert Repo.get!(GameSession, session.id).status == :cancelled
    end

    test "encerra também uma sala em andamento", %{conn: conn, scope: scope} do
      session = game_session_fixture(%{host: scope.user, status: :in_progress})

      data =
        conn |> post(~p"/api/v1/game-sessions/#{session.join_code}/cancel") |> json_response(200)

      assert data["data"]["status"] == "cancelled"
    end

    test "cancelar duas vezes responde 409 na segunda", %{conn: conn, scope: scope} do
      session = game_session_fixture(%{host: scope.user, status: :waiting})

      assert conn
             |> post(~p"/api/v1/game-sessions/#{session.join_code}/cancel")
             |> json_response(200)

      conn = post(conn, ~p"/api/v1/game-sessions/#{session.join_code}/cancel")

      assert json_response(conn, 409) == %{
               "errors" => %{"detail" => "Esta sala já foi encerrada"}
             }
    end

    test "a sala de outro host responde 404", %{conn: conn} do
      other = game_session_fixture(%{status: :waiting})

      conn = post(conn, ~p"/api/v1/game-sessions/#{other.join_code}/cancel")

      assert json_response(conn, 404) == @not_found
      assert Repo.get!(GameSession, other.id).status == :waiting
    end

    test "sem token responde 401", %{scope: scope} do
      session = game_session_fixture(%{host: scope.user, status: :waiting})
      conn = post(anonymous(), ~p"/api/v1/game-sessions/#{session.join_code}/cancel")

      assert json_response(conn, 401) == @unauthorized
      assert Repo.get!(GameSession, session.id).status == :waiting
    end
  end

  describe "a credencial não é reemitida" do
    test "nenhuma outra resposta carrega o participant_token", context do
      %{conn: conn, scope: scope} = context
      session = game_session_fixture(%{host: scope.user, status: :waiting})
      :ok = Games.subscribe(session.id)

      join =
        anonymous()
        |> post(~p"/api/v1/game-sessions/#{session.join_code}/join", %{"nickname" => "Ana"})
        |> json_response(201)

      token = join["data"]["participant_token"]
      participant = Repo.get!(Participant, join["data"]["participant"]["id"])
      connect(participant)

      credential = put_api_participant(anonymous(), token)

      responses = [
        get(anonymous(), ~p"/api/v1/game-sessions/#{session.join_code}"),
        get(conn, ~p"/api/v1/game-sessions/#{session.join_code}/host"),
        get(credential, ~p"/api/v1/game-sessions/#{session.join_code}/participants"),
        get(credential, ~p"/api/v1/game-sessions/#{session.join_code}/me"),
        post(credential, ~p"/api/v1/game-sessions/#{session.join_code}/rejoin"),
        post(conn, ~p"/api/v1/game-sessions/#{session.join_code}/start"),
        post(conn, ~p"/api/v1/game-sessions/#{session.join_code}/cancel")
      ]

      for response <- responses do
        assert response.status in [200, 201]
        refute response.resp_body =~ token
        refute response.resp_body =~ "participant_token"
      end
    end
  end

  describe "paridade entre a web e a API" do
    test "a capacidade da sala é a mesma nos dois canais", %{conn: conn} do
      session = game_session_fixture(%{status: :waiting})
      for _index <- 1..25, do: participant_fixture(session)

      {:ok, lv, _html} = live(build_conn(), ~p"/join")

      html =
        lv
        |> form("#join-form", join: %{code: session.join_code, nickname: "Ana"})
        |> render_submit()

      assert html =~ "Sala lotada."

      response =
        post(conn, ~p"/api/v1/game-sessions/#{session.join_code}/join", %{"nickname" => "Ana"})

      assert json_response(response, 409) == %{"errors" => %{"detail" => "Sala lotada"}}
      assert Games.reserved_slots(session) == 25
    end

    test "o apelido tomado é recusado nos dois canais", %{conn: conn} do
      session = game_session_fixture(%{status: :waiting})
      _taken = participant_fixture(session, %{nickname: "Ana"})

      {:ok, lv, _html} = live(build_conn(), ~p"/join")

      html =
        lv
        |> form("#join-form", join: %{code: session.join_code, nickname: "ana"})
        |> render_submit()

      assert html =~ "apelido já está em uso nesta sala"

      response =
        post(conn, ~p"/api/v1/game-sessions/#{session.join_code}/join", %{"nickname" => "ana"})

      assert json_response(response, 409) == %{
               "errors" => %{"detail" => "Este apelido já está em uso nesta sala"}
             }

      assert Games.reserved_slots(session) == 1
    end

    test "uma sala por pessoa vale nos dois canais", %{conn: conn, user: user} do
      session = game_session_fixture(%{status: :waiting})
      elsewhere = game_session_fixture(%{status: :waiting})
      _participant = participant_fixture(elsewhere, %{user: user})

      {:ok, lv, _html} = build_conn() |> log_in_user(user) |> live(~p"/join")

      html =
        lv
        |> form("#join-form", join: %{code: session.join_code, nickname: "Ana"})
        |> render_submit()

      assert html =~ "Você já está em outra sala"

      response =
        post(conn, ~p"/api/v1/game-sessions/#{session.join_code}/join", %{"nickname" => "Ana"})

      assert json_response(response, 409) == %{
               "errors" => %{"detail" => "Você já está participando de outra sala"}
             }

      assert Games.reserved_slots(session) == 0
    end

    test "o ciclo de vida da sala é o mesmo nos dois canais", %{conn: conn, scope: scope} do
      quiz = quiz_fixture(scope)

      web =
        build_conn()
        |> log_in_user(scope.user)
        |> post(~p"/game-sessions", %{"quiz_id" => quiz.id})

      assert redirected_to(web) == ~p"/quizzes"

      assert Phoenix.Flash.get(web.assigns.flash, :error) =~
               "Adicione ao menos uma pergunta"

      response = post(conn, ~p"/api/v1/game-sessions", %{"quiz_id" => quiz.id})

      assert json_response(response, 422) == %{
               "errors" => %{"detail" => "O quiz precisa ter ao menos uma pergunta"}
             }

      refute Repo.exists?(GameSession)
    end
  end

  describe "o token de participação não abre as portas do host" do
    test "nenhum endpoint de host aceita a credencial de participação" do
      session = game_session_fixture(%{status: :waiting})
      {_participant, token} = credentialed_participant_fixture(session)
      credential = put_api_participant(anonymous(), token)

      responses = [
        post(credential, ~p"/api/v1/game-sessions", %{"quiz_id" => 1}),
        get(credential, ~p"/api/v1/game-sessions/#{session.join_code}/host"),
        post(credential, ~p"/api/v1/game-sessions/#{session.join_code}/start"),
        post(credential, ~p"/api/v1/game-sessions/#{session.join_code}/cancel")
      ]

      for response <- responses do
        assert json_response(response, 401) == @unauthorized
      end
    end

    test "um token de participação apresentado como Bearer não vale nada" do
      session = game_session_fixture(%{status: :waiting})
      {_participant, token} = credentialed_participant_fixture(session)

      conn =
        anonymous()
        |> put_req_header("authorization", "Bearer " <> token)
        |> get(~p"/api/v1/game-sessions/#{session.join_code}/participants")

      assert json_response(conn, 401) == @unauthorized
    end

    test "um JWT apresentado como Participant não vale nada", %{user: user} do
      session = game_session_fixture(%{status: :waiting})

      conn =
        anonymous()
        |> put_api_participant(api_token(user))
        |> get(~p"/api/v1/game-sessions/#{session.join_code}/participants")

      assert json_response(conn, 401) == @unauthorized
    end

    test "um token de participação desconhecido responde 401" do
      session = game_session_fixture(%{status: :waiting})
      {unknown, _hash} = ParticipantToken.build()

      conn =
        anonymous()
        |> put_api_participant(unknown)
        |> get(~p"/api/v1/game-sessions/#{session.join_code}/me")

      assert json_response(conn, 401) == @unauthorized
    end
  end

  defp anonymous, do: put_req_header(build_conn(), "accept", "application/json")

  defp playable_quiz(%Scope{} = scope, attrs \\ %{}) do
    quiz = quiz_fixture(scope, attrs)
    question_fixture(scope, quiz)

    quiz
  end

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp connect(%Participant{} = participant) do
    {:ok, connection} = Agent.start(fn -> :connected end)
    on_exit(fn -> Process.exit(connection, :kill) end)

    {:ok, _ref} = Presence.track_participant(connection, participant, Ecto.UUID.generate())
    assert_receive {:presence_changed, _session_id}, 2_000

    connection
  end
end
