defmodule LiveQuizWeb.Api.V1.GamePlayControllerTest do
  # A presença, o LiveView da paridade e o monitor de ausência vivem em
  # processos diferentes do teste, então a sandbox precisa ser compartilhada:
  # uma corrida assíncrona não emprestaria conexão a nenhum deles.
  use LiveQuizWeb.ConnCase, async: false

  import Ecto.Query

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import LiveQuiz.QuizzesFixtures
  import Phoenix.LiveViewTest

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Accounts.User
  alias LiveQuiz.Games
  alias LiveQuiz.Games.Answer
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.HostMonitor
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Games.Presence
  alias LiveQuiz.Repo

  @unauthorized %{"errors" => %{"detail" => "Não autenticado"}}
  @forbidden %{"errors" => %{"detail" => "Acesso negado"}}
  @not_found %{"errors" => %{"detail" => "Não encontrado"}}

  # Longa de propósito: nenhum teste aqui espera a ausência do host virar
  # contagem regressiva, e uma janela curta encerraria salas no meio da suíte.
  @grace :timer.seconds(60)

  setup do
    host = user_fixture()
    session = game_session_fixture(%{host: host, status: :in_progress})
    questions = snapshot_fixture(session, count: 3)
    {participant, token} = credentialed_participant_fixture(session, %{nickname: "Ana"})

    :ok = Games.subscribe(session.id)

    %{
      host: host,
      host_scope: Scope.for_user(host),
      session: session,
      questions: questions,
      participant: participant,
      token: token
    }
  end

  describe "POST /api/v1/game-sessions com a duração da pergunta" do
    setup :register_and_log_in_api_user

    test "aceita cada duração permitida", %{conn: conn, scope: scope} do
      for duration <- GameSession.question_durations() do
        quiz = playable_quiz(scope)

        data =
          conn
          |> post(~p"/api/v1/game-sessions", %{
            "quiz_id" => quiz.id,
            "question_duration_seconds" => duration
          })
          |> json_response(201)

        assert data["data"]["question_duration_seconds"] == duration

        session = Repo.get_by!(GameSession, join_code: data["data"]["code"])
        assert session.question_duration_seconds == duration
        {:ok, _cancelled} = Games.cancel_game_session(scope, session)
      end
    end

    test "sem duração no corpo, a sala nasce com o padrão de 30", %{conn: conn, scope: scope} do
      quiz = playable_quiz(scope)

      data =
        conn |> post(~p"/api/v1/game-sessions", %{"quiz_id" => quiz.id}) |> json_response(201)

      assert data["data"]["question_duration_seconds"] == 30
    end

    test "uma duração fora da lista responde 422 em português", %{conn: conn, scope: scope} do
      quiz = playable_quiz(scope)

      data =
        conn
        |> post(~p"/api/v1/game-sessions", %{
          "quiz_id" => quiz.id,
          "question_duration_seconds" => 45
        })
        |> json_response(422)

      assert %{"errors" => %{"question_duration_seconds" => [message]}} = data
      assert message =~ "durações disponíveis"
      refute Games.get_active_session_for_host(scope)
    end
  end

  describe "POST /api/v1/game-sessions/:code/next" do
    test "abre a primeira pergunta quando a partida ainda não avançou", context do
      %{host: host, session: session} = context

      data = advance(host, session, nil) |> json_response(200)

      assert data["data"]["question_number"] == 1
      assert data["data"]["question_state"] == "open"
      assert data["data"]["question_count"] == 3
      assert data["data"]["last_question"] == false
      assert data["data"]["question_text"] == "Pergunta 1 da partida"
      assert {:ok, _at, 0} = DateTime.from_iso8601(data["data"]["ends_at"])
      assert String.ends_with?(data["data"]["ends_at"], "Z")
    end

    test "avança para a pergunta seguinte com a posição corrente", context do
      %{host: host, host_scope: scope, session: session} = context
      {:ok, _open} = Games.advance_question(scope, session, nil)

      data = advance(host, session, 1) |> json_response(200)

      assert data["data"]["question_number"] == 2
      assert data["data"]["question_text"] == "Pergunta 2 da partida"
    end

    test "a última pergunta se anuncia como última", context do
      %{host: host, host_scope: scope, session: session} = context
      {:ok, first} = Games.advance_question(scope, session, nil)
      {:ok, _second} = Games.advance_question(scope, first, 1)

      data = advance(host, session, 2) |> json_response(200)

      assert data["data"]["question_number"] == 3
      assert data["data"]["last_question"] == true
    end

    test "sem expected_position responde 422", %{host: host, session: session} do
      data =
        host
        |> jwt()
        |> post(~p"/api/v1/game-sessions/#{session.join_code}/next", %{})
        |> json_response(422)

      assert data["errors"]["code"] == "invalid_expected_position"
      assert data["errors"]["detail"] =~ "expected_position"
      assert Repo.get!(GameSession, session.id).current_question_position == nil
    end

    test "com uma posição desatualizada responde 409 stale", context do
      %{host: host, host_scope: scope, session: session} = context
      {:ok, first} = Games.advance_question(scope, session, nil)
      {:ok, _second} = Games.advance_question(scope, first, 1)

      data = advance(host, session, 1) |> json_response(409)

      assert data["errors"]["code"] == "stale"
      assert Repo.get!(GameSession, session.id).current_question_position == 2
    end

    test "além da última pergunta responde 409 no_more_questions", context do
      %{host: host, host_scope: scope, session: session} = context
      {:ok, first} = Games.advance_question(scope, session, nil)
      {:ok, second} = Games.advance_question(scope, first, 1)
      {:ok, third} = Games.advance_question(scope, second, 2)
      {:ok, _closed} = Games.close_question(scope, third)

      data = advance(host, session, 3) |> json_response(409)

      assert data["errors"]["code"] == "no_more_questions"
    end

    test "sem token responde 401", %{session: session} do
      assert anonymous()
             |> post(~p"/api/v1/game-sessions/#{session.join_code}/next", %{
               "expected_position" => nil
             })
             |> json_response(401) == @unauthorized
    end

    test "a credencial de participante não comanda", %{session: session, token: token} do
      assert token
             |> credential()
             |> post(~p"/api/v1/game-sessions/#{session.join_code}/next", %{
               "expected_position" => nil
             })
             |> json_response(401) == @unauthorized
    end

    test "outro host autenticado responde 403", %{session: session} do
      assert user_fixture() |> advance(session, nil) |> json_response(403) == @forbidden
    end

    test "um código inexistente responde 404", %{host: host} do
      stranger = game_session_fixture(%{status: :in_progress})
      {:ok, _cancelled} = Games.cancel_game_session(Scope.for_user(host(stranger)), stranger)

      assert host
             |> jwt()
             |> post(~p"/api/v1/game-sessions/ZZZZZZ/next", %{"expected_position" => nil})
             |> json_response(404) == @not_found
    end

    for status <- [:waiting, :cancelled, :expired, :finished] do
      test "uma partida em #{status} responde 409" do
        elsewhere = user_fixture()
        session = game_session_fixture(%{host: elsewhere, status: unquote(status)})

        data = advance(elsewhere, session, nil) |> json_response(409)

        assert data["errors"]["code"] == "invalid_status"
      end
    end
  end

  describe "POST /api/v1/game-sessions/:code/close-question" do
    test "encerra a pergunta aberta e revela o gabarito", context do
      %{host: host, host_scope: scope, session: session, questions: [first | _rest]} = context
      {:ok, _open} = Games.advance_question(scope, session, nil)

      data = close(host, session) |> json_response(200)

      assert data["data"]["question_state"] == "closed"
      assert data["data"]["seconds_left"] == 0
      assert Repo.get!(GameSession, session.id).current_question_closed_at

      correct = Enum.find(first.answer_options, & &1.is_correct)
      assert Enum.find(data["data"]["options"], &(&1["id"] == correct.id))["is_correct"] == true
    end

    test "encerrar de novo devolve 200 sem mexer no instante", context do
      %{host: host, host_scope: scope, session: session} = context
      {:ok, _open} = Games.advance_question(scope, session, nil)

      assert close(host, session) |> json_response(200)
      closed_at = Repo.get!(GameSession, session.id).current_question_closed_at

      assert close(host, session) |> json_response(200)
      assert Repo.get!(GameSession, session.id).current_question_closed_at == closed_at
    end

    test "sem pergunta aberta responde 409", %{host: host, session: session} do
      data = close(host, session) |> json_response(409)

      assert data["errors"]["code"] == "no_open_question"
    end

    test "sem token responde 401", %{session: session} do
      assert anonymous()
             |> post(~p"/api/v1/game-sessions/#{session.join_code}/close-question")
             |> json_response(401) == @unauthorized
    end

    test "a credencial de participante não comanda", %{session: session, token: token} do
      assert token
             |> credential()
             |> post(~p"/api/v1/game-sessions/#{session.join_code}/close-question")
             |> json_response(401) == @unauthorized
    end

    test "outro host autenticado responde 403", %{session: session} do
      assert user_fixture() |> close(session) |> json_response(403) == @forbidden
    end

    test "um código inexistente responde 404", %{host: host} do
      assert host
             |> jwt()
             |> post(~p"/api/v1/game-sessions/ZZZZZZ/close-question")
             |> json_response(404) == @not_found
    end

    for status <- [:waiting, :cancelled, :expired, :finished] do
      test "uma partida em #{status} responde 409" do
        elsewhere = user_fixture()
        session = game_session_fixture(%{host: elsewhere, status: unquote(status)})

        assert close(elsewhere, session) |> json_response(409) |> get_in(["errors", "code"]) ==
                 "invalid_status"
      end
    end
  end

  describe "POST /api/v1/game-sessions/:code/finish" do
    test "finaliza a partida e resume o que foi jogado", context do
      %{host: host, host_scope: scope, session: session, participant: participant} = context
      {:ok, open} = Games.advance_question(scope, session, nil)
      [option | _rest] = current_options(open)
      answer_fixture(participant, option)

      data = finish(host, session) |> json_response(200)

      assert data["data"]["status"] == "finished"
      assert data["data"]["question_count"] == 3
      assert data["data"]["questions_played"] == 1
      assert data["data"]["answers_count"] == 1
      assert data["data"]["participants_count"] == 1
      assert {:ok, _at, 0} = DateTime.from_iso8601(data["data"]["finished_at"])
      assert Repo.get!(GameSession, session.id).status == :finished
    end

    test "finalizar de novo devolve 200 sem mexer no encerramento", context do
      %{host: host, session: session} = context

      assert first = finish(host, session) |> json_response(200)
      assert second = finish(host, session) |> json_response(200)
      assert first["data"]["finished_at"] == second["data"]["finished_at"]
    end

    test "sem token responde 401", %{session: session} do
      assert anonymous()
             |> post(~p"/api/v1/game-sessions/#{session.join_code}/finish")
             |> json_response(401) == @unauthorized
    end

    test "a credencial de participante não comanda", %{session: session, token: token} do
      assert token
             |> credential()
             |> post(~p"/api/v1/game-sessions/#{session.join_code}/finish")
             |> json_response(401) == @unauthorized
    end

    test "outro host autenticado responde 403", %{session: session} do
      assert user_fixture() |> finish(session) |> json_response(403) == @forbidden
    end

    test "um código inexistente responde 404", %{host: host} do
      assert host
             |> jwt()
             |> post(~p"/api/v1/game-sessions/ZZZZZZ/finish")
             |> json_response(404) == @not_found
    end

    for status <- [:waiting, :cancelled, :expired] do
      test "uma sala em #{status} responde 409" do
        elsewhere = user_fixture()
        session = game_session_fixture(%{host: elsewhere, status: unquote(status)})

        assert finish(elsewhere, session) |> json_response(409) |> get_in(["errors", "code"]) ==
                 "invalid_status"
      end
    end
  end

  describe "POST /api/v1/game-sessions/:code/answers" do
    setup :open_first_question

    test "registra a alternativa escolhida", context do
      %{session: session, token: token, options: [option | _rest]} = context

      data = answer(token, session, option.id) |> json_response(201)

      assert data["data"]["answer_option_id"] == option.id
      assert data["data"]["question_closed"] == false
      assert {:ok, _at, 0} = DateTime.from_iso8601(data["data"]["answered_at"])
      assert String.ends_with?(data["data"]["answered_at"], "Z")
    end

    test "trocar a resposta mantém uma única linha", context do
      %{participant: participant, session: session, token: token, options: options} = context
      [first, second | _rest] = options

      assert answer(token, session, first.id) |> json_response(201)
      data = answer(token, session, second.id) |> json_response(201)

      assert data["data"]["answer_option_id"] == second.id
      assert Repo.aggregate(answers_of(participant), :count) == 1
    end

    test "fora do prazo responde 409 time_is_up", context do
      %{session: session, token: token, options: [option | _rest]} = context
      ending_in(session, -1)

      data = answer(token, session, option.id) |> json_response(409)

      assert data["errors"]["code"] == "time_is_up"
      assert Repo.aggregate(Answer, :count) == 0
    end

    test "com a pergunta encerrada responde 409 question_closed", context do
      %{host_scope: scope, session: session, token: token, options: [option | _rest]} = context
      {:ok, _closed} = Games.close_question(scope, Repo.get!(GameSession, session.id))

      data = answer(token, session, option.id) |> json_response(409)

      assert data["errors"]["code"] == "question_closed"
    end

    test "a alternativa de outra pergunta responde 422 option_not_found", context do
      %{session: session, token: token, questions: [_first, second | _rest]} = context
      [elsewhere | _rest] = second.answer_options

      data = answer(token, session, elsewhere.id) |> json_response(422)

      assert data["errors"]["code"] == "option_not_found"
    end

    test "sem answer_option_id no corpo responde 422", context do
      %{session: session, token: token} = context

      data =
        token
        |> credential()
        |> post(~p"/api/v1/game-sessions/#{session.join_code}/answers", %{})
        |> json_response(422)

      assert data["errors"]["code"] == "invalid_answer_option_id"
    end

    test "sem credencial nenhuma responde 401", context do
      %{session: session, options: [option | _rest]} = context

      assert anonymous()
             |> post(~p"/api/v1/game-sessions/#{session.join_code}/answers", %{
               "answer_option_id" => option.id
             })
             |> json_response(401) == @unauthorized
    end

    test "o host com o JWT dele responde 401 — o host não joga", context do
      %{host: host, session: session, options: [option | _rest]} = context

      assert host
             |> jwt()
             |> post(~p"/api/v1/game-sessions/#{session.join_code}/answers", %{
               "answer_option_id" => option.id
             })
             |> json_response(401) == @unauthorized
    end

    test "a credencial de outra partida responde 403", context do
      %{session: session, options: [option | _rest]} = context
      elsewhere = game_session_fixture(%{status: :in_progress})
      {_participant, other_token} = credentialed_participant_fixture(elsewhere)

      assert answer(other_token, session, option.id) |> json_response(403) == @forbidden
    end

    test "quem saiu da sala responde 403", context do
      %{participant: participant, session: session, token: token, options: [option | _rest]} =
        context

      {:ok, _left} = Games.leave_game_session(participant)

      data = answer(token, session, option.id) |> json_response(403)

      assert data["errors"]["code"] == "left_session"
    end

    test "a última resposta que faltava encerra a pergunta no próprio corpo", context do
      %{participant: participant, session: session, token: token, options: [option | _rest]} =
        context

      {second, second_token} = credentialed_participant_fixture(session, %{nickname: "Bruno"})
      connect(participant)
      connect(second)

      first = answer(token, session, option.id) |> json_response(201)
      assert first["data"]["question_closed"] == false

      last = answer(second_token, session, option.id) |> json_response(201)
      assert last["data"]["question_closed"] == true
      assert Repo.get!(GameSession, session.id).current_question_closed_at
    end
  end

  describe "GET /api/v1/game-sessions/:code/state" do
    setup :open_first_question

    test "o host recebe a contagem de respostas e não a escolha de ninguém", context do
      %{host: host, participant: participant, session: session, options: [option | _rest]} =
        context

      answer_fixture(participant, option)

      data = host |> jwt() |> get(state_path(session)) |> json_response(200)

      assert data["data"]["answers_count"] == 1
      refute Map.has_key?(data["data"], "my_answer_option_id")
      assert data["data"]["status"] == "in_progress"
      assert data["data"]["question_number"] == 1
      assert data["data"]["question_count"] == 3
      assert data["data"]["question_state"] == "open"
    end

    test "quem joga recebe a própria escolha e não a contagem", context do
      %{participant: participant, session: session, token: token, options: [option | _rest]} =
        context

      answer_fixture(participant, option)

      data = token |> credential() |> get(state_path(session)) |> json_response(200)

      assert data["data"]["my_answer_option_id"] == option.id
      refute Map.has_key?(data["data"], "answers_count")
    end

    test "quem ainda não respondeu recebe a escolha nula, não a ausência do campo", context do
      %{session: session, token: token} = context

      data = token |> credential() |> get(state_path(session)) |> json_response(200)

      assert Map.has_key?(data["data"], "my_answer_option_id")
      assert data["data"]["my_answer_option_id"] == nil
    end

    test "com a pergunta aberta nenhuma alternativa traz o gabarito", context do
      %{session: session, token: token} = context

      data = token |> credential() |> get(state_path(session)) |> json_response(200)

      assert length(data["data"]["options"]) == 4

      for option <- data["data"]["options"] do
        refute Map.has_key?(option, "is_correct")
        assert Enum.sort(Map.keys(option)) == ~w(id position text)
      end
    end

    test "depois do encerramento o gabarito aparece para quem jogou", context do
      %{host_scope: scope, session: session, token: token, questions: [first | _rest]} = context
      {:ok, _closed} = Games.close_question(scope, Repo.get!(GameSession, session.id))

      data = token |> credential() |> get(state_path(session)) |> json_response(200)

      correct = Enum.find(first.answer_options, & &1.is_correct)

      assert data["data"]["question_state"] == "closed"

      for option <- data["data"]["options"] do
        assert option["is_correct"] == (option["id"] == correct.id)
      end
    end

    test "o host enxerga o gabarito mesmo com a pergunta aberta", context do
      %{host: host, session: session, questions: [first | _rest]} = context

      data = host |> jwt() |> get(state_path(session)) |> json_response(200)

      correct = Enum.find(first.answer_options, & &1.is_correct)
      assert Enum.find(data["data"]["options"], &(&1["id"] == correct.id))["is_correct"] == true
    end

    test "o prazo sai em ISO 8601 UTC e o resto do tempo o acompanha", context do
      %{session: session, token: token} = context

      data = token |> credential() |> get(state_path(session)) |> json_response(200)

      assert {:ok, _at, 0} = DateTime.from_iso8601(data["data"]["ends_at"])
      assert String.ends_with?(data["data"]["ends_at"], "Z")
      assert data["data"]["seconds_left"] in 0..30
    end

    test "a partida finalizada continua respondendo a quem jogou", context do
      %{host_scope: scope, session: session, token: token} = context
      {:ok, _finished} = Games.finish_game_session(scope, Repo.get!(GameSession, session.id))

      data = token |> credential() |> get(state_path(session)) |> json_response(200)

      assert data["data"]["status"] == "finished"
    end

    test "sem credencial nenhuma responde 401", %{session: session} do
      assert anonymous() |> get(state_path(session)) |> json_response(401) == @unauthorized
    end

    test "um terceiro autenticado responde 403", %{session: session} do
      assert user_fixture() |> jwt() |> get(state_path(session)) |> json_response(403) ==
               @forbidden
    end

    test "a credencial de outra partida responde 403", %{session: session} do
      elsewhere = game_session_fixture(%{status: :in_progress})
      {_participant, other_token} = credentialed_participant_fixture(elsewhere)

      assert other_token |> credential() |> get(state_path(session)) |> json_response(403) ==
               @forbidden
    end

    test "um código inexistente responde 404", %{token: token} do
      assert token
             |> credential()
             |> get(~p"/api/v1/game-sessions/ZZZZZZ/state")
             |> json_response(404) == @not_found
    end
  end

  describe "GET /api/v1/game-sessions/:code/questions/:position/results" do
    setup :open_first_question

    test "a pergunta encerrada traz gabarito, distribuição e o resultado de quem jogou",
         context do
      %{participant: participant, host_scope: scope, session: session, token: token} = context
      %{options: [correct, wrong | _rest]} = context

      {other, _other_token} = credentialed_participant_fixture(session, %{nickname: "Bruno"})
      _absent = participant_fixture(session, %{nickname: "Carla"})
      answer_fixture(participant, correct)
      answer_fixture(other, wrong)
      {:ok, _closed} = Games.close_question(scope, Repo.get!(GameSession, session.id))

      data = token |> credential() |> get(results_path(session, 1)) |> json_response(200)

      assert data["data"]["position"] == 1
      assert data["data"]["question_count"] == 3
      assert data["data"]["answers_count"] == 2
      assert data["data"]["participants_count"] == 3
      assert data["data"]["no_answer_count"] == 1
      assert data["data"]["my_answer_option_id"] == correct.id
      assert data["data"]["my_answer_correct"] == true

      assert Enum.map(data["data"]["options"], & &1["count"]) == [1, 1, 0, 0]
      assert Enum.map(data["data"]["options"], & &1["is_correct"]) == [true, false, false, false]
    end

    test "o host apura sem resultado próprio", context do
      %{host: host, host_scope: scope, participant: participant, session: session} = context
      %{options: [correct | _rest]} = context

      answer_fixture(participant, correct)
      {:ok, _closed} = Games.close_question(scope, Repo.get!(GameSession, session.id))

      data = host |> jwt() |> get(results_path(session, 1)) |> json_response(200)

      assert data["data"]["answers_count"] == 1
      assert data["data"]["my_answer_option_id"] == nil
      assert data["data"]["my_answer_correct"] == nil
    end

    test "a pergunta ainda aberta responde 409 question_open", context do
      %{session: session, token: token} = context

      data = token |> credential() |> get(results_path(session, 1)) |> json_response(409)

      assert data["errors"]["code"] == "question_open"
    end

    test "uma pergunta que a partida nem alcançou responde 409", context do
      %{session: session, token: token} = context

      data = token |> credential() |> get(results_path(session, 3)) |> json_response(409)

      assert data["errors"]["code"] == "question_open"
    end

    test "uma posição inexistente responde 404", context do
      %{host_scope: scope, session: session, token: token} = context
      {:ok, _closed} = Games.close_question(scope, Repo.get!(GameSession, session.id))

      assert token |> credential() |> get(results_path(session, 9)) |> json_response(404) ==
               @not_found
    end

    test "uma posição que não é número responde 404", context do
      %{session: session, token: token} = context

      assert token
             |> credential()
             |> get(~p"/api/v1/game-sessions/#{session.join_code}/questions/primeira/results")
             |> json_response(404) == @not_found
    end

    test "um terceiro autenticado responde 403", %{session: session} do
      assert user_fixture() |> jwt() |> get(results_path(session, 1)) |> json_response(403) ==
               @forbidden
    end

    test "sem credencial nenhuma responde 401", %{session: session} do
      assert anonymous() |> get(results_path(session, 1)) |> json_response(401) == @unauthorized
    end
  end

  describe "uma partida inteira pela API" do
    test "criar, entrar, iniciar, avançar, responder, encerrar, avançar e finalizar" do
      host = user_fixture()
      scope = Scope.for_user(host)
      quiz = playable_quiz(scope, 2)

      room =
        host
        |> jwt()
        |> post(~p"/api/v1/game-sessions", %{
          "quiz_id" => quiz.id,
          "question_duration_seconds" => 60
        })
        |> json_response(201)

      code = room["data"]["code"]
      assert room["data"]["question_duration_seconds"] == 60

      joined =
        anonymous()
        |> post(~p"/api/v1/game-sessions/#{code}/join", %{"nickname" => "Ana"})
        |> json_response(201)

      token = joined["data"]["participant_token"]
      session = Repo.get_by!(GameSession, join_code: code)
      :ok = Games.subscribe(session.id)
      session |> participant_of() |> connect()

      assert host
             |> jwt()
             |> post(~p"/api/v1/game-sessions/#{code}/start")
             |> json_response(200)
             |> get_in(["data", "status"]) == "in_progress"

      first = advance(host, session, nil) |> json_response(200)
      assert first["data"]["question_number"] == 1

      [option | _rest] = current_options(Repo.get!(GameSession, session.id))

      assert token
             |> credential()
             |> post(~p"/api/v1/game-sessions/#{code}/answers", %{"answer_option_id" => option.id})
             |> json_response(201)

      assert close(host, session) |> json_response(200) |> get_in(["data", "question_state"]) ==
               "closed"

      assert token
             |> credential()
             |> get(results_path(session, 1))
             |> json_response(200)
             |> get_in(["data", "answers_count"]) == 1

      second = advance(host, session, 1) |> json_response(200)
      assert second["data"]["question_number"] == 2
      assert second["data"]["last_question"] == true

      ending = finish(host, session) |> json_response(200)
      assert ending["data"]["status"] == "finished"
      assert ending["data"]["questions_played"] == 2
      assert ending["data"]["answers_count"] == 1
      assert Repo.get!(GameSession, session.id).status == :finished
    end
  end

  describe "envelopes e datas" do
    setup :open_first_question

    test "toda resposta bem-sucedida vem só com data", context do
      %{host: host, host_scope: scope, session: session, token: token, options: [option | _rest]} =
        context

      answered = answer(token, session, option.id)
      {:ok, closed} = Games.close_question(scope, Repo.get!(GameSession, session.id))

      responses = [
        answered,
        token |> credential() |> get(state_path(session)),
        host |> jwt() |> get(state_path(session)),
        token |> credential() |> get(results_path(session, 1)),
        advance(host, closed, 1),
        close(host, session),
        finish(host, session)
      ]

      for response <- responses do
        assert response.status in [200, 201]
        assert response |> json_response(response.status) |> Map.keys() == ["data"]
      end
    end

    test "toda recusa vem só com errors, em pt-BR e com código estável", context do
      %{host: host, session: session, token: token, questions: [_first, second | _rest]} = context
      [elsewhere | _rest] = second.answer_options

      refusals = [
        {answer(token, session, elsewhere.id), 422, "option_not_found"},
        {token |> credential() |> get(results_path(session, 1)), 409, "question_open"},
        {advance(host, session, 3), 409, "stale"}
      ]

      for {response, status, code} <- refusals do
        body = json_response(response, status)

        assert Map.keys(body) == ["errors"]
        assert body["errors"]["code"] == code
        assert is_binary(body["errors"]["detail"])
      end
    end

    test "toda data sai em ISO 8601 UTC", context do
      %{host: host, session: session, token: token, options: [option | _rest]} = context

      answered = answer(token, session, option.id) |> json_response(201)
      state = token |> credential() |> get(state_path(session)) |> json_response(200)
      ending = finish(host, session) |> json_response(200)

      for at <- [
            answered["data"]["answered_at"],
            state["data"]["ends_at"],
            ending["data"]["finished_at"]
          ] do
        assert {:ok, _at, 0} = DateTime.from_iso8601(at)
        assert String.ends_with?(at, "Z")
      end
    end

    test "antes do primeiro avanço o estado é pendente" do
      pending = game_session_fixture(%{status: :in_progress})
      _questions = snapshot_fixture(pending, count: 2)
      {_participant, pending_token} = credentialed_participant_fixture(pending)

      data = pending_token |> credential() |> get(state_path(pending)) |> json_response(200)

      assert data["data"]["question_state"] == "pending"
      assert data["data"]["question_number"] == nil
      assert data["data"]["question_text"] == nil
      assert data["data"]["ends_at"] == nil
      assert data["data"]["seconds_left"] == nil
      assert data["data"]["options"] == []
    end
  end

  describe "a mesma partida conduzida metade pela web e metade pela API" do
    setup :own_monitor

    test "o host comanda pela tela e o participante joga pela API", context do
      %{conn: conn, host: host, session: session, token: token} = context

      {:ok, lv, _html} =
        live(log_in_user(conn, host), ~p"/game-sessions/#{session.join_code}/host")

      # Metade web: o host abre a pergunta 1 pela tela.
      render_click(lv, "advance_question", %{"position" => ""})
      assert lv |> element("#question-progress") |> render() =~ "Pergunta 1 de 3"

      # Metade API: o participante lê o estado e responde.
      state = token |> credential() |> get(state_path(session)) |> json_response(200)
      assert state["data"]["question_number"] == 1
      assert state["data"]["question_state"] == "open"

      [option | _rest] = current_options(Repo.get!(GameSession, session.id))
      assert answer(token, session, option.id) |> json_response(201)

      # A tela do host vê a resposta que entrou pela API.
      assert lv |> element("#answers-count") |> render() =~ "<strong>1</strong>"

      # Metade web outra vez: o host encerra pela tela.
      render_click(lv, "close_question", %{})

      results = token |> credential() |> get(results_path(session, 1)) |> json_response(200)
      assert results["data"]["answers_count"] == 1
      assert results["data"]["my_answer_option_id"] == option.id

      # E o avanço pela API continua de onde a tela parou.
      assert advance(host, session, 1)
             |> json_response(200)
             |> get_in(["data", "question_number"]) ==
               2

      assert render(lv) =~ "Pergunta 2 de 3"
    end
  end

  ## Helpers

  defp anonymous, do: put_req_header(build_conn(), "accept", "application/json")

  defp credential(token), do: put_api_participant(anonymous(), token)

  defp jwt(%User{} = user), do: log_in_api_user(anonymous(), user)

  defp advance(%User{} = user, %GameSession{} = session, expected) do
    post(jwt(user), ~p"/api/v1/game-sessions/#{session.join_code}/next", %{
      "expected_position" => expected
    })
  end

  defp close(%User{} = user, %GameSession{} = session) do
    post(jwt(user), ~p"/api/v1/game-sessions/#{session.join_code}/close-question")
  end

  defp finish(%User{} = user, %GameSession{} = session) do
    post(jwt(user), ~p"/api/v1/game-sessions/#{session.join_code}/finish")
  end

  defp answer(token, %GameSession{} = session, option_id) do
    post(credential(token), ~p"/api/v1/game-sessions/#{session.join_code}/answers", %{
      "answer_option_id" => option_id
    })
  end

  defp state_path(%GameSession{} = session),
    do: ~p"/api/v1/game-sessions/#{session.join_code}/state"

  defp results_path(%GameSession{} = session, position),
    do: ~p"/api/v1/game-sessions/#{session.join_code}/questions/#{position}/results"

  defp answers_of(%Participant{id: id}), do: where(Answer, [a], a.participant_id == ^id)

  # A partida já em andamento abre a primeira pergunta pelo contexto, que é o
  # mesmo caminho da tela do host: o que se testa aqui é o endpoint, não o
  # avanço.
  defp open_first_question(%{host_scope: scope, session: session}) do
    {:ok, open} = Games.advance_question(scope, session, nil)

    %{session: open, options: current_options(open)}
  end

  defp current_options(%GameSession{} = session) do
    {:ok, question} = Games.get_snapshot_question(session, session.current_question_position)

    Enum.sort_by(question.answer_options, & &1.position)
  end

  # As colunas da pergunta corrente não têm changeset de propósito — mover a
  # partida de uma pergunta para a outra é papel do contexto —, então o teste
  # que precisa de um prazo específico escreve direto.
  defp ending_in(%GameSession{} = session, seconds) do
    session
    |> Ecto.Changeset.change(%{
      current_question_ends_at: DateTime.add(DateTime.utc_now(), seconds, :second)
    })
    |> Repo.update!()
  end

  defp participant_of(%GameSession{id: id}),
    do: Repo.one!(where(Participant, [p], p.game_session_id == ^id))

  defp host(%GameSession{host_id: host_id}), do: Repo.get!(User, host_id)

  defp playable_quiz(%Scope{} = scope, questions \\ 1) do
    quiz = quiz_fixture(scope)
    for _ <- 1..questions, do: question_fixture(scope, quiz)

    quiz
  end

  # O teste assina o tópico da sala no setup, então esperar o aviso de presença
  # garante que o rastreamento já foi processado antes da asserção.
  defp connect(%Participant{} = participant) do
    {:ok, connection} = Agent.start(fn -> :connected end)
    on_exit(fn -> Process.exit(connection, :kill) end)

    {:ok, _ref} = Presence.track_participant(connection, participant, Ecto.UUID.generate())
    assert_receive {:presence_changed, _session_id}, 2_000

    connection
  end

  # Um monitor próprio, parado ao fim do teste: parar o processo espera o `cast`
  # que a presença do host acabou de mandar terminar.
  defp own_monitor(_context) do
    {:ok, monitor} = HostMonitor.start_link(name: nil, grace_period: @grace)
    Application.put_env(:live_quiz, :host_monitor, monitor)

    on_exit(fn ->
      Application.delete_env(:live_quiz, :host_monitor)
      if Process.alive?(monitor), do: GenServer.stop(monitor)
    end)

    %{monitor: monitor}
  end
end
