defmodule LiveQuiz.GamesTest do
  use LiveQuiz.DataCase, async: true

  import ExUnit.CaptureLog
  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import LiveQuiz.QuizzesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias LiveQuiz.Accounts
  alias LiveQuiz.Accounts.User
  alias LiveQuiz.Games
  alias LiveQuiz.Games.Answer
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.JoinCode
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Games.ParticipantToken
  alias LiveQuiz.Quizzes
  alias LiveQuiz.Quizzes.AnswerOption
  alias LiveQuiz.Quizzes.Question

  describe "create_game_session/2" do
    setup :host_with_playable_quiz

    test "abre a sala a partir de um quiz pronto", %{scope: scope, quiz: quiz} do
      assert {:ok, session} = Games.create_game_session(scope, quiz.id)

      assert session.status == :waiting
      assert session.host_id == scope.user.id
      assert session.quiz_id == quiz.id
      assert session.quiz_title == quiz.title
      assert String.length(session.join_code) == GameSession.join_code_length()
      assert JoinCode.valid_format?(session.join_code)

      assert Repo.get!(GameSession, session.id).join_code == session.join_code
    end

    test "a sala nasce sem marcas de início, fim ou presença", %{scope: scope, quiz: quiz} do
      assert {:ok, session} = Games.create_game_session(scope, quiz.id)

      assert is_nil(session.started_at)
      assert is_nil(session.finished_at)
      assert is_nil(session.host_connection_id)
      assert is_nil(session.host_disconnected_at)
      assert is_nil(session.expires_at)
    end

    test "o código não usa as letras O e I nem os dígitos 0 e 1", %{scope: scope, quiz: quiz} do
      assert {:ok, session} = Games.create_game_session(scope, quiz.id)

      refute String.contains?(session.join_code, ["O", "0", "I", "1"])
    end

    test "aceita o id do quiz como string", %{scope: scope, quiz: quiz} do
      assert {:ok, session} = Games.create_game_session(scope, to_string(quiz.id))
      assert session.quiz_id == quiz.id
    end

    test "recusa um quiz sem perguntas e não persiste nada", %{scope: scope} do
      empty_quiz = quiz_fixture(scope, %{title: "Quiz vazio"})

      assert {:error, :quiz_not_playable} = Games.create_game_session(scope, empty_quiz.id)
      refute hosted_any?(scope)
    end

    test "levanta NoResultsError para o quiz de outra pessoa", %{scope: scope} do
      other_scope = user_scope_fixture()
      other_quiz = playable_quiz(other_scope)

      assert_raise Ecto.NoResultsError, fn ->
        Games.create_game_session(scope, other_quiz.id)
      end

      refute hosted_any?(scope)
    end

    test "levanta NoResultsError para um quiz inexistente", %{scope: scope} do
      assert_raise Ecto.NoResultsError, fn ->
        Games.create_game_session(scope, 0)
      end
    end

    test "recusa quando o host já tem uma sala aguardando", %{scope: scope, quiz: quiz} do
      game_session_fixture(%{host: scope.user, status: :waiting})

      assert {:error, :host_already_in_session} = Games.create_game_session(scope, quiz.id)
    end

    test "recusa quando o host já tem uma sala em andamento", %{scope: scope, quiz: quiz} do
      game_session_fixture(%{host: scope.user, status: :in_progress})

      assert {:error, :host_already_in_session} = Games.create_game_session(scope, quiz.id)
    end

    test "permite abrir outra sala depois de cancelar a anterior", %{scope: scope, quiz: quiz} do
      cancelled = game_session_fixture(%{host: scope.user, status: :cancelled})

      assert {:ok, session} = Games.create_game_session(scope, quiz.id)
      assert session.join_code != cancelled.join_code
    end

    test "recusa quem está participando de outra sala", %{scope: scope, quiz: quiz} do
      other_session = game_session_fixture()
      participant_fixture(other_session, %{user: scope.user})

      assert {:error, :already_participating} = Games.create_game_session(scope, quiz.id)
      refute hosted_any?(scope)
    end

    test "libera quem já foi dispensado da sala anterior", %{scope: scope, quiz: quiz} do
      other_session = game_session_fixture()
      participant_fixture(other_session, %{user: scope.user, released_at: now()})

      assert {:ok, _session} = Games.create_game_session(scope, quiz.id)
    end

    # Renomear com a sala aberta é recusado desde a F2-07, então o cenário só
    # existe depois que a sala é encerrada — o título copiado continua sendo o
    # da época da partida, que é o que a coluna existe para guardar.
    test "preserva o título mesmo depois de renomear o quiz", %{scope: scope, quiz: quiz} do
      assert {:ok, session} = Games.create_game_session(scope, quiz.id)
      assert {:ok, _cancelled} = Games.cancel_game_session(scope, session)
      assert {:ok, _quiz} = Quizzes.update_quiz(scope, quiz, %{title: "Geografia do Brasil"})

      assert Repo.get!(GameSession, session.id).quiz_title == quiz.title
    end

    test "tenta de novo quando o código sorteado já está em uso", %{scope: scope, quiz: quiz} do
      taken = game_session_fixture(%{status: :waiting})
      stub_join_codes([taken.join_code, "K7P4Q2"])

      log =
        capture_log(fn ->
          assert {:ok, session} = Games.create_game_session(scope, quiz.id)
          assert session.join_code == "K7P4Q2"
        end)

      assert log =~ "collided with a live room"
    end

    test "desiste depois de cinco colisões e não persiste nada", %{scope: scope, quiz: quiz} do
      taken = game_session_fixture(%{status: :waiting})
      stub_join_codes([taken.join_code])

      log =
        capture_log(fn ->
          assert {:error, :code_generation_failed} = Games.create_game_session(scope, quiz.id)
        end)

      assert log |> String.split("collided with a live room") |> length() == 6
      refute hosted_any?(scope)
    end

    test "devolve o changeset quando a validação do código falha", %{scope: scope, quiz: quiz} do
      stub_join_codes(["nao-e-codigo"])

      assert {:error, %Ecto.Changeset{} = changeset} = Games.create_game_session(scope, quiz.id)
      assert %{join_code: [_message | _]} = errors_on(changeset)
      refute hosted_any?(scope)
    end
  end

  describe "create_game_session/2 sob concorrência" do
    test "dez chamadas do mesmo host produzem exatamente uma sala" do
      scope = user_scope_fixture()
      quiz = playable_quiz(scope)

      results = in_parallel(1..10, fn _index -> Games.create_game_session(scope, quiz.id) end)

      assert Enum.count(results, &match?({:ok, %GameSession{}}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :host_already_in_session})) == 9
      assert Repo.aggregate(hosted_by(scope), :count) == 1
    end

    test "dez chamadas de quem já participa de outra sala não abrem nenhuma" do
      scope = user_scope_fixture()
      quiz = playable_quiz(scope)
      participant_fixture(game_session_fixture(), %{user: scope.user})

      results = in_parallel(1..10, fn _index -> Games.create_game_session(scope, quiz.id) end)

      assert Enum.all?(results, &(&1 == {:error, :already_participating}))
      refute hosted_any?(scope)
    end

    test "vinte hosts diferentes recebem vinte códigos distintos" do
      hosts =
        Enum.map(1..20, fn _index ->
          scope = user_scope_fixture()
          {scope, playable_quiz(scope)}
        end)

      results =
        in_parallel(hosts, fn {scope, quiz} -> Games.create_game_session(scope, quiz.id) end)

      codes =
        Enum.map(results, fn result ->
          assert {:ok, %GameSession{join_code: code}} = result
          code
        end)

      assert codes |> MapSet.new() |> MapSet.size() == 20
    end
  end

  describe "get_game_session_by_code/1" do
    test "encontra uma sala aguardando participantes" do
      session = game_session_fixture(%{status: :waiting})

      assert {:ok, found} = Games.get_game_session_by_code(session.join_code)
      assert found.id == session.id
    end

    test "encontra uma sala em andamento" do
      session = game_session_fixture(%{status: :in_progress})

      assert {:ok, found} = Games.get_game_session_by_code(session.join_code)
      assert found.id == session.id
    end

    test "normaliza espaços e minúsculas" do
      session = game_session_fixture(%{status: :waiting})
      typed = " #{String.downcase(session.join_code)} "

      assert {:ok, found} = Games.get_game_session_by_code(typed)
      assert found.id == session.id
    end

    test "não devolve sala cancelada" do
      session = game_session_fixture(%{status: :cancelled})

      assert Games.get_game_session_by_code(session.join_code) == {:error, :not_found}
    end

    test "não devolve sala expirada" do
      session = game_session_fixture(%{status: :expired})

      assert Games.get_game_session_by_code(session.join_code) == {:error, :not_found}
    end

    test "não devolve sala encerrada" do
      session = game_session_fixture(%{status: :finished})

      assert Games.get_game_session_by_code(session.join_code) == {:error, :not_found}
    end

    test "devolve not_found para um código inexistente" do
      assert Games.get_game_session_by_code("K7P4Q2") == {:error, :not_found}
    end

    test "rejeita um código fora do alfabeto sem consultar o banco" do
      assert_no_query(fn ->
        assert Games.get_game_session_by_code("K7P4Q0") == {:error, :not_found}
        assert Games.get_game_session_by_code("ABC") == {:error, :not_found}
        assert Games.get_game_session_by_code("") == {:error, :not_found}
      end)
    end

    test "rejeita valores que não são texto" do
      assert Games.get_game_session_by_code(nil) == {:error, :not_found}
    end
  end

  describe "get_hosted_session_by_code!/2" do
    test "devolve a sala aguardando participantes do host do escopo" do
      scope = user_scope_fixture()
      session = game_session_fixture(%{host: scope.user, status: :waiting})

      assert Games.get_hosted_session_by_code!(scope, session.join_code).id == session.id
    end

    test "devolve a sala em andamento do host do escopo" do
      scope = user_scope_fixture()
      session = game_session_fixture(%{host: scope.user, status: :in_progress})

      assert Games.get_hosted_session_by_code!(scope, session.join_code).id == session.id
    end

    test "continua devolvendo a sala depois de cancelada" do
      scope = user_scope_fixture()
      session = game_session_fixture(%{host: scope.user, status: :cancelled})

      assert Games.get_hosted_session_by_code!(scope, session.join_code).id == session.id
    end

    test "continua devolvendo a sala depois de expirada" do
      scope = user_scope_fixture()
      session = game_session_fixture(%{host: scope.user, status: :expired})

      assert Games.get_hosted_session_by_code!(scope, session.join_code).id == session.id
    end

    test "normaliza espaços e minúsculas" do
      scope = user_scope_fixture()
      session = game_session_fixture(%{host: scope.user, status: :waiting})

      typed = " #{String.downcase(session.join_code)} "

      assert Games.get_hosted_session_by_code!(scope, typed).id == session.id
    end

    test "devolve a mais recente quando o código foi reaproveitado" do
      scope = user_scope_fixture()
      code = unique_join_code()

      old_session =
        game_session_fixture(%{host: scope.user, status: :cancelled, join_code: code})

      current = game_session_fixture(%{host: scope.user, status: :waiting, join_code: code})

      assert current.id != old_session.id
      assert Games.get_hosted_session_by_code!(scope, code).id == current.id
    end

    test "levanta NoResultsError para a sala de outra pessoa" do
      session = game_session_fixture(%{status: :waiting})
      other_scope = user_scope_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        Games.get_hosted_session_by_code!(other_scope, session.join_code)
      end
    end

    test "levanta NoResultsError para um código inexistente" do
      assert_raise Ecto.NoResultsError, fn ->
        Games.get_hosted_session_by_code!(user_scope_fixture(), "K7P4Q2")
      end
    end

    test "levanta NoResultsError para um código fora do alfabeto" do
      assert_raise Ecto.NoResultsError, fn ->
        Games.get_hosted_session_by_code!(user_scope_fixture(), "nada")
      end
    end
  end

  describe "get_game_session!/2" do
    test "devolve a sala do host do escopo" do
      scope = user_scope_fixture()
      session = game_session_fixture(%{host: scope.user})

      assert Games.get_game_session!(scope, session.id).id == session.id
    end

    test "levanta NoResultsError para a sala de outra pessoa" do
      session = game_session_fixture()
      other_scope = user_scope_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        Games.get_game_session!(other_scope, session.id)
      end
    end

    test "levanta NoResultsError para um id inexistente" do
      scope = user_scope_fixture()

      assert_raise Ecto.NoResultsError, fn -> Games.get_game_session!(scope, 0) end
    end
  end

  describe "get_active_session_for_host/1" do
    test "devolve a sala ativa do host" do
      scope = user_scope_fixture()
      session = game_session_fixture(%{host: scope.user, status: :waiting})

      assert Games.get_active_session_for_host(scope).id == session.id
    end

    test "devolve nil quando o host não tem sala" do
      assert Games.get_active_session_for_host(user_scope_fixture()) == nil
    end

    test "devolve nil quando a única sala do host está encerrada" do
      scope = user_scope_fixture()
      game_session_fixture(%{host: scope.user, status: :cancelled})

      assert Games.get_active_session_for_host(scope) == nil
    end
  end

  describe "engaged_in_session?/1" do
    test "é verdadeiro para quem apresenta uma sala ativa" do
      scope = user_scope_fixture()
      game_session_fixture(%{host: scope.user, status: :in_progress})

      assert Games.engaged_in_session?(scope)
    end

    test "é verdadeiro para quem participa de uma sala" do
      scope = user_scope_fixture()
      participant_fixture(game_session_fixture(), %{user: scope.user})

      assert Games.engaged_in_session?(scope)
    end

    test "é falso para quem já foi dispensado da sala" do
      scope = user_scope_fixture()
      participant_fixture(game_session_fixture(), %{user: scope.user, released_at: now()})

      refute Games.engaged_in_session?(scope)
    end

    test "é falso para quem só tem sala encerrada" do
      scope = user_scope_fixture()
      game_session_fixture(%{host: scope.user, status: :finished})

      refute Games.engaged_in_session?(scope)
    end

    test "é falso para quem está livre" do
      refute Games.engaged_in_session?(user_scope_fixture())
    end
  end

  describe "join_game_session/4 para visitante" do
    setup :waiting_session

    test "cria a participação sem conta e devolve a credencial", %{session: session} do
      assert {:ok, participant, token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"})

      assert participant.game_session_id == session.id
      assert is_nil(participant.user_id)
      assert participant.nickname == "Ana"
      assert participant.nickname_normalized == "ana"
      assert participant.joined_at
      assert is_nil(participant.left_at)
      assert is_nil(participant.released_at)
      assert {:ok, hash} = ParticipantToken.hash(token)
      assert participant.access_token_hash == hash
    end

    test "aceita o código digitado em minúsculas e com espaços", %{session: session} do
      typed = " #{String.downcase(session.join_code)} "

      assert {:ok, participant, _token} =
               Games.join_game_session(nil, typed, %{"nickname" => "Ana"})

      assert participant.game_session_id == session.id
    end

    test "guarda apenas o resumo do token, nunca o token em claro", %{session: session} do
      assert {:ok, participant, token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"})

      %{rows: [row]} =
        Repo.query!("SELECT * FROM participants WHERE id = $1", [participant.id])

      refute Enum.any?(row, &contains?(&1, token))
    end

    test "preserva a grafia do apelido e apara as pontas", %{session: session} do
      assert {:ok, participant, _token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "  AnA  "})

      assert participant.nickname == "AnA"
      assert participant.nickname_normalized == "ana"
    end

    test "devolve session_not_found para um código inexistente" do
      assert Games.join_game_session(nil, "K7P4Q2", %{"nickname" => "Ana"}) ==
               {:error, :session_not_found}
    end

    test "devolve session_not_found para um código fora do alfabeto" do
      assert Games.join_game_session(nil, "K7P4Q0", %{"nickname" => "Ana"}) ==
               {:error, :session_not_found}
    end

    test "devolve session_not_joinable para uma sala em andamento" do
      session = game_session_fixture(%{status: :in_progress})

      assert Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"}) ==
               {:error, :session_not_joinable}
    end

    test "não encontra sala cancelada nem expirada" do
      cancelled = game_session_fixture(%{status: :cancelled})
      expired = game_session_fixture(%{status: :expired})

      assert Games.join_game_session(nil, cancelled.join_code, %{"nickname" => "Ana"}) ==
               {:error, :session_not_found}

      assert Games.join_game_session(nil, expired.join_code, %{"nickname" => "Ana"}) ==
               {:error, :session_not_found}
    end
  end

  describe "join_game_session/4 para usuário autenticado" do
    setup :waiting_session

    test "vincula a participação à conta", %{session: session} do
      scope = user_scope_fixture()

      assert {:ok, participant, _token} =
               Games.join_game_session(scope, session.join_code, %{"nickname" => "Ana"})

      assert participant.user_id == scope.user.id
    end

    test "o apelido escolhido não altera o nome da conta", %{session: session} do
      scope = user_scope_fixture()

      assert {:ok, participant, _token} =
               Games.join_game_session(scope, session.join_code, %{"nickname" => "Aninha"})

      assert participant.nickname == "Aninha"
      assert Repo.get!(User, scope.user.id).name == "Ana Souza"
    end

    test "recusa quem já participa de outra sala", %{session: session} do
      scope = user_scope_fixture()
      participant_fixture(game_session_fixture(), %{user: scope.user})

      assert Games.join_game_session(scope, session.join_code, %{"nickname" => "Ana"}) ==
               {:error, :already_in_another_session}

      assert Games.reserved_slots(session) == 0
    end

    test "aceita quem já foi dispensado da sala anterior", %{session: session} do
      scope = user_scope_fixture()
      participant_fixture(game_session_fixture(), %{user: scope.user, released_at: now()})

      assert {:ok, _participant, _token} =
               Games.join_game_session(scope, session.join_code, %{"nickname" => "Ana"})
    end

    test "recusa o host de uma sala ativa", %{session: session} do
      scope = user_scope_fixture()
      game_session_fixture(%{host: scope.user, status: :waiting})

      assert Games.join_game_session(scope, session.join_code, %{"nickname" => "Ana"}) ==
               {:error, :already_in_another_session}
    end

    test "recusa o host da própria sala", %{session: session, host: host} do
      assert Games.join_game_session(user_scope_fixture(host), session.join_code, %{
               "nickname" => "Ana"
             }) == {:error, :already_in_another_session}
    end

    test "aceita quem só apresentou salas encerradas", %{session: session} do
      scope = user_scope_fixture()
      game_session_fixture(%{host: scope.user, status: :cancelled})

      assert {:ok, _participant, _token} =
               Games.join_game_session(scope, session.join_code, %{"nickname" => "Ana"})
    end

    test "quem participa não consegue abrir sala depois", %{session: session} do
      scope = user_scope_fixture()
      quiz = playable_quiz(scope)

      assert {:ok, _participant, _token} =
               Games.join_game_session(scope, session.join_code, %{"nickname" => "Ana"})

      assert Games.create_game_session(scope, quiz.id) == {:error, :already_participating}
    end
  end

  describe "join_game_session/4 e o apelido" do
    setup :waiting_session

    test "recusa um apelido com um caractere", %{session: session} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "A"})

      assert %{nickname: [_message | _]} = errors_on(changeset)
      assert Games.reserved_slots(session) == 0
    end

    test "aceita um apelido de dois caracteres", %{session: session} do
      assert {:ok, participant, _token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Jô"})

      assert participant.nickname == "Jô"
    end

    test "aceita um apelido de vinte caracteres", %{session: session} do
      nickname = String.duplicate("a", 20)

      assert {:ok, participant, _token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => nickname})

      assert participant.nickname == nickname
    end

    test "recusa um apelido de vinte e um caracteres", %{session: session} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Games.join_game_session(nil, session.join_code, %{
                 "nickname" => String.duplicate("a", 21)
               })

      assert %{nickname: [_message | _]} = errors_on(changeset)
    end

    test "recusa um apelido com emoji", %{session: session} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana 🎉"})

      assert %{nickname: [_message | _]} = errors_on(changeset)
    end

    test "aceita hífen, sublinhado, números e acentos", %{session: session} do
      assert {:ok, participant, _token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana-Paula_1"})

      assert participant.nickname == "Ana-Paula_1"
    end

    test "recusa um apelido só de espaços", %{session: session} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "   "})

      assert %{nickname: [_message | _]} = errors_on(changeset)
    end

    test "recusa um apelido nulo e a ausência do campo", %{session: session} do
      assert {:error, %Ecto.Changeset{}} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => nil})

      assert {:error, %Ecto.Changeset{}} = Games.join_game_session(nil, session.join_code, %{})
    end

    test "recusa um apelido repetido ignorando caixa e espaços", %{session: session} do
      participant_fixture(session, %{nickname: "Ana"})

      assert Games.join_game_session(nil, session.join_code, %{"nickname" => " ANA "}) ==
               {:error, :nickname_taken}
    end

    test "distingue acentos e espaços internos", %{session: session} do
      participant_fixture(session, %{nickname: "Ana"})

      assert {:ok, _participant, _token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Aná"})
    end

    test "mantém o apelido reservado depois da saída voluntária", %{session: session} do
      participant_fixture(session, %{nickname: "Ana", left_at: now(), released_at: now()})

      assert Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"}) ==
               {:error, :nickname_taken}
    end

    test "mantém o apelido reservado de quem está desconectado", %{session: session} do
      participant_fixture(session, %{nickname: "Ana", connection_id: nil})

      assert Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"}) ==
               {:error, :nickname_taken}
    end

    test "o mesmo apelido vale em salas diferentes", %{session: session} do
      other_session = game_session_fixture(%{status: :waiting})
      participant_fixture(other_session, %{nickname: "Ana"})

      assert {:ok, _participant, _token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"})
    end
  end

  describe "join_game_session/4 e a capacidade" do
    setup :waiting_session

    test "aceita vinte e cinco participações e recusa a vigésima sexta", %{session: session} do
      results =
        Enum.map(1..25, fn index ->
          Games.join_game_session(nil, session.join_code, %{"nickname" => "Pessoa #{index}"})
        end)

      assert Enum.all?(results, &match?({:ok, %Participant{}, _token}, &1))
      assert Games.reserved_slots(session) == 25
      assert Games.available_slots(session) == 0

      assert Games.join_game_session(nil, session.join_code, %{"nickname" => "Tarde demais"}) ==
               {:error, :session_full}
    end

    test "não cria fila de espera quando a sala lota", %{session: session} do
      fill_session(session, 25)

      assert Games.join_game_session(nil, session.join_code, %{"nickname" => "Tarde demais"}) ==
               {:error, :session_full}

      assert Games.reserved_slots(session) == 25
    end

    test "quem saiu continua ocupando a vaga", %{session: session} do
      fill_session(session, 22)
      for _index <- 1..3, do: participant_fixture(session, %{left_at: now(), released_at: now()})

      assert Games.reserved_slots(session) == 25

      assert Games.join_game_session(nil, session.join_code, %{"nickname" => "Tarde demais"}) ==
               {:error, :session_full}
    end

    test "quem foi dispensado continua ocupando a vaga", %{session: session} do
      fill_session(session, 24)
      participant_fixture(session, %{released_at: now()})

      assert Games.join_game_session(nil, session.join_code, %{"nickname" => "Tarde demais"}) ==
               {:error, :session_full}
    end

    test "o host não ocupa vaga", %{session: session, host: host} do
      fill_session(session, 25)

      assert Games.reserved_slots(session) == 25
      assert {:ok, participants} = Games.list_participants(session, user_scope_fixture(host))
      refute Enum.any?(participants, &(&1.user_id == host.id))
    end

    test "a lotação de uma sala não afeta a outra", %{session: session} do
      other_session = game_session_fixture(%{status: :waiting})
      fill_session(session, 25)

      assert {:ok, _participant, _token} =
               Games.join_game_session(nil, other_session.join_code, %{"nickname" => "Ana"})
    end
  end

  describe "join_game_session/4 e a volta para a mesma sala" do
    setup :waiting_session

    test "o visitante que apresenta a credencial recebe a mesma participação", %{
      session: session
    } do
      assert {:ok, participant, token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"})

      assert {:ok, same, same_token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Outra"},
                 known_tokens: [token]
               )

      assert same.id == participant.id
      assert same.nickname == "Ana"
      assert same_token == token
      assert Games.reserved_slots(session) == 1
    end

    test "o visitante sem credencial vira uma nova participação", %{session: session} do
      assert {:ok, first, _token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"})

      assert {:ok, second, _token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Bia"})

      assert first.id != second.id
      assert Games.reserved_slots(session) == 2
    end

    test "o visitante com credencial de outra sala é recusado", %{session: session} do
      other_session = game_session_fixture(%{status: :waiting})

      assert {:ok, _participant, token} =
               Games.join_game_session(nil, other_session.join_code, %{"nickname" => "Ana"})

      assert Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"},
               known_tokens: [token]
             ) == {:error, :already_in_another_session}
    end

    test "a credencial já dispensada não prende o visitante", %{session: session} do
      other_session = game_session_fixture(%{status: :waiting})

      assert {:ok, participant, token} =
               Games.join_game_session(nil, other_session.join_code, %{"nickname" => "Ana"})

      participant |> Participant.connection_changeset(%{released_at: now()}) |> Repo.update!()

      assert {:ok, _participant, _token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"},
                 known_tokens: [token]
               )
    end

    test "tokens malformados são ignorados sem erro", %{session: session} do
      assert {:ok, _participant, _token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"},
                 known_tokens: ["não é token", nil, 42, ""]
               )
    end

    test "só as vinte primeiras credenciais apresentadas são consideradas", %{session: session} do
      other_session = game_session_fixture(%{status: :waiting})

      assert {:ok, _participant, token} =
               Games.join_game_session(nil, other_session.join_code, %{"nickname" => "Ana"})

      padding = for _index <- 1..20, do: elem(ParticipantToken.build(), 0)

      assert {:ok, _participant, _token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"},
                 known_tokens: padding ++ [token]
               )
    end

    test "o autenticado recebe a mesma participação e uma credencial nova", %{session: session} do
      scope = user_scope_fixture()

      assert {:ok, participant, first_token} =
               Games.join_game_session(scope, session.join_code, %{"nickname" => "Ana"})

      assert {:ok, same, second_token} =
               Games.join_game_session(scope, session.join_code, %{"nickname" => "Outra"})

      assert same.id == participant.id
      assert same.nickname == "Ana"
      assert second_token != first_token
      assert Games.reserved_slots(session) == 1
      assert Games.get_participant_by_token(first_token) == {:error, :not_found}
      assert {:ok, found} = Games.get_participant_by_token(second_token)
      assert found.id == participant.id
    end

    test "o autenticado que apresenta a credencial mantém a mesma", %{session: session} do
      scope = user_scope_fixture()

      assert {:ok, _participant, token} =
               Games.join_game_session(scope, session.join_code, %{"nickname" => "Ana"})

      assert {:ok, _same, ^token} =
               Games.join_game_session(scope, session.join_code, %{"nickname" => "Ana"},
                 known_tokens: [token]
               )
    end

    test "voltar não passa pela contagem de vagas", %{session: session} do
      scope = user_scope_fixture()

      assert {:ok, participant, _token} =
               Games.join_game_session(scope, session.join_code, %{"nickname" => "Ana"})

      fill_session(session, 24)
      assert Games.reserved_slots(session) == 25

      assert {:ok, same, _token} =
               Games.join_game_session(scope, session.join_code, %{"nickname" => "Ana"})

      assert same.id == participant.id
      assert Games.reserved_slots(session) == 25
    end
  end

  describe "join_game_session/4 sob concorrência" do
    test "trinta pessoas disputando vinte e cinco vagas produzem cinco recusas" do
      session = game_session_fixture(%{status: :waiting})

      results =
        in_parallel(1..30, fn index ->
          Games.join_game_session(nil, session.join_code, %{"nickname" => "Pessoa #{index}"})
        end)

      assert Enum.count(results, &match?({:ok, %Participant{}, _token}, &1)) == 25
      assert Enum.count(results, &(&1 == {:error, :session_full})) == 5
      assert Games.reserved_slots(session) == 25
    end

    test "dez pessoas com o mesmo apelido produzem uma única participação" do
      session = game_session_fixture(%{status: :waiting})

      results =
        in_parallel(1..10, fn _index ->
          Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"})
        end)

      assert Enum.count(results, &match?({:ok, %Participant{}, _token}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :nickname_taken})) == 9
      assert Games.reserved_slots(session) == 1
    end

    test "cinco tentativas do mesmo autenticado em salas diferentes entram em uma só" do
      scope = user_scope_fixture()
      sessions = for _index <- 1..5, do: game_session_fixture(%{status: :waiting})

      results =
        in_parallel(sessions, fn session ->
          Games.join_game_session(scope, session.join_code, %{"nickname" => "Ana"})
        end)

      assert Enum.count(results, &match?({:ok, %Participant{}, _token}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :already_in_another_session})) == 4

      assert Repo.aggregate(participations_of(scope), :count) == 1
    end

    test "salas diferentes não disputam a mesma contagem de vagas" do
      sessions = for _index <- 1..5, do: game_session_fixture(%{status: :waiting})

      results =
        in_parallel(sessions, fn session ->
          Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"})
        end)

      assert Enum.all?(results, &match?({:ok, %Participant{}, _token}, &1))
      assert Enum.all?(sessions, &(Games.reserved_slots(&1) == 1))
    end
  end

  describe "get_participant_by_token/1" do
    setup :waiting_session

    test "encontra a participação a partir do token em claro", %{session: session} do
      assert {:ok, participant, token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"})

      assert {:ok, found} = Games.get_participant_by_token(token)
      assert found.id == participant.id
    end

    test "encontra a participação de uma sala em andamento", %{session: session} do
      assert {:ok, participant, token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"})

      session |> GameSession.status_changeset(:in_progress) |> Repo.update!()

      assert {:ok, found} = Games.get_participant_by_token(token)
      assert found.id == participant.id
    end

    test "não encontra a participação de uma sala encerrada", %{session: session} do
      assert {:ok, _participant, token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"})

      session |> GameSession.status_changeset(:cancelled) |> Repo.update!()

      assert Games.get_participant_by_token(token) == {:error, :not_found}
    end

    test "devolve not_found para um token inexistente" do
      {token, _hash} = ParticipantToken.build()

      assert Games.get_participant_by_token(token) == {:error, :not_found}
    end

    test "devolve not_found para um token malformado" do
      assert Games.get_participant_by_token("não é token") == {:error, :not_found}
      assert Games.get_participant_by_token(nil) == {:error, :not_found}
    end
  end

  describe "get_participation_by_token/1" do
    setup :waiting_session

    test "encontra a participação a partir do token em claro", %{session: session} do
      assert {:ok, participant, token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"})

      assert {:ok, found} = Games.get_participation_by_token(token)
      assert found.id == participant.id
    end

    test "continua encontrando a participação de uma sala encerrada", %{session: session} do
      assert {:ok, participant, token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"})

      session |> GameSession.status_changeset(:cancelled) |> Repo.update!()

      assert {:ok, found} = Games.get_participation_by_token(token)
      assert found.id == participant.id
      assert Games.get_participant_by_token(token) == {:error, :not_found}
    end

    test "continua encontrando a participação de quem saiu", %{session: session} do
      assert {:ok, participant, token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"})

      {:ok, _participant} = Games.leave_game_session(participant)

      assert {:ok, found} = Games.get_participation_by_token(token)
      assert found.id == participant.id
    end

    test "devolve not_found para um token inexistente" do
      {token, _hash} = ParticipantToken.build()

      assert Games.get_participation_by_token(token) == {:error, :not_found}
    end

    test "devolve not_found para um token malformado" do
      assert Games.get_participation_by_token("não é token") == {:error, :not_found}
      assert Games.get_participation_by_token(nil) == {:error, :not_found}
      assert Games.get_participation_by_token("") == {:error, :not_found}
    end
  end

  describe "list_participants/2" do
    setup :waiting_session

    test "o host vê a lista em ordem de entrada", %{session: session, host: host} do
      first = participant_fixture(session, %{joined_at: minutes_ago(3)})
      second = participant_fixture(session, %{joined_at: minutes_ago(2)})
      third = participant_fixture(session, %{joined_at: minutes_ago(1)})

      assert {:ok, participants} = Games.list_participants(session, user_scope_fixture(host))
      assert Enum.map(participants, & &1.id) == [first.id, second.id, third.id]
    end

    test "o participante autenticado vê a lista", %{session: session} do
      scope = user_scope_fixture()

      assert {:ok, _participant, _token} =
               Games.join_game_session(scope, session.join_code, %{"nickname" => "Ana"})

      assert {:ok, [_only]} = Games.list_participants(session, scope)
    end

    test "o visitante com credencial vê a lista", %{session: session} do
      assert {:ok, participant, _token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"})

      assert {:ok, [listed]} = Games.list_participants(session, participant)
      assert listed.id == participant.id
    end

    test "um terceiro autenticado é recusado", %{session: session} do
      participant_fixture(session)

      assert Games.list_participants(session, user_scope_fixture()) == {:error, :unauthorized}
    end

    test "um visitante sem credencial é recusado", %{session: session} do
      participant_fixture(session)

      assert Games.list_participants(session, nil) == {:error, :unauthorized}
    end

    test "a credencial de outra sala é recusada", %{session: session} do
      other_session = game_session_fixture(%{status: :waiting})

      assert {:ok, participant, _token} =
               Games.join_game_session(nil, other_session.join_code, %{"nickname" => "Ana"})

      assert Games.list_participants(session, participant) == {:error, :unauthorized}
    end

    test "quem já foi dispensado perde o acesso à lista", %{session: session} do
      participant = participant_fixture(session, %{released_at: now()})

      assert Games.list_participants(session, participant) == {:error, :unauthorized}
    end

    test "omite quem saiu e mantém quem está desconectado", %{session: session, host: host} do
      connected = participant_fixture(session, %{connection_id: Ecto.UUID.generate()})
      disconnected = participant_fixture(session, %{connection_id: nil})
      participant_fixture(session, %{left_at: now(), released_at: now()})

      assert {:ok, participants} = Games.list_participants(session, user_scope_fixture(host))

      assert Enum.sort(Enum.map(participants, & &1.id)) ==
               Enum.sort([connected.id, disconnected.id])
    end

    test "devolve lista vazia para uma sala sem participantes", %{session: session, host: host} do
      assert Games.list_participants(session, user_scope_fixture(host)) == {:ok, []}
    end
  end

  describe "reserved_slots/1 e available_slots/1" do
    setup :waiting_session

    test "uma sala vazia tem todas as vagas livres", %{session: session} do
      assert Games.reserved_slots(session) == 0
      assert Games.available_slots(session) == Games.max_participants()
    end

    test "uma sala parcialmente ocupada desconta as participações", %{session: session} do
      fill_session(session, 3)

      assert Games.reserved_slots(session) == 3
      assert Games.available_slots(session) == 22
    end

    test "uma sala cheia não tem vagas", %{session: session} do
      fill_session(session, 25)

      assert Games.reserved_slots(session) == 25
      assert Games.available_slots(session) == 0
    end

    test "quem saiu e quem foi dispensado continuam contando", %{session: session} do
      participant_fixture(session, %{left_at: now(), released_at: now()})
      participant_fixture(session, %{released_at: now()})

      assert Games.reserved_slots(session) == 2
      assert Games.available_slots(session) == 23
    end

    test "a sala aceita no máximo vinte e cinco participações" do
      assert Games.max_participants() == 25
    end
  end

  describe "change_join/1" do
    test "normaliza o código antes de validar" do
      changeset = Games.change_join(%{"code" => " k7p4q2 ", "nickname" => "Ana"})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :code) == "K7P4Q2"
    end

    test "recusa código fora do alfabeto sem tocar no banco" do
      changeset = Games.change_join(%{"code" => "K7P4Q0", "nickname" => "Ana"})

      refute changeset.valid?
      assert %{code: [message]} = errors_on(changeset)
      assert message =~ "código inválido"
    end

    test "recusa código com o tamanho errado" do
      refute Games.change_join(%{"code" => "K7P4", "nickname" => "Ana"}).valid?
      refute Games.change_join(%{"code" => "K7P4Q2X", "nickname" => "Ana"}).valid?
    end

    test "exige o código" do
      changeset = Games.change_join(%{"nickname" => "Ana"})

      assert %{code: ["informe o código da sala"]} = errors_on(changeset)
    end

    test "aplica as mesmas regras de apelido do cadastro" do
      code = "K7P4Q2"

      assert %{nickname: [_short]} =
               errors_on(Games.change_join(%{"code" => code, "nickname" => "A"}))

      assert Games.change_join(%{"code" => code, "nickname" => "Al"}).valid?
      assert Games.change_join(%{"code" => code, "nickname" => String.duplicate("a", 20)}).valid?

      assert %{nickname: [_long]} =
               errors_on(
                 Games.change_join(%{"code" => code, "nickname" => String.duplicate("a", 21)})
               )

      assert %{nickname: [emoji]} =
               errors_on(Games.change_join(%{"code" => code, "nickname" => "Ana 🎉"}))

      assert emoji =~ "use apenas letras"

      assert %{nickname: ["can't be blank"]} =
               errors_on(Games.change_join(%{"code" => code, "nickname" => "   "}))
    end

    test "não promete a unicidade do apelido" do
      session = game_session_fixture()
      participant_fixture(session, %{nickname: "Ana"})

      changeset = Games.change_join(%{"code" => session.join_code, "nickname" => "Ana"})

      assert changeset.valid?
    end

    test "sem argumento devolve um changeset sem erros para exibir" do
      changeset = Games.change_join()

      refute changeset.valid?
      assert changeset.errors != []
      assert changeset.action == nil
    end
  end

  describe "preview_by_code/1" do
    test "traz o título do quiz e a disponibilidade da sala" do
      session = game_session_fixture(%{quiz_title: "Quiz de História"})

      assert {:ok, preview} = Games.preview_by_code(session.join_code)
      assert preview == %{quiz_title: "Quiz de História", available: true}
    end

    test "não vaza a lista nem a contagem de participantes" do
      session = game_session_fixture()
      participant_fixture(session, %{nickname: "Ana"})

      assert {:ok, preview} = Games.preview_by_code(session.join_code)
      assert Map.keys(preview) == [:available, :quiz_title]
    end

    test "aceita o código em minúsculas e com espaços" do
      session = game_session_fixture()

      assert {:ok, _preview} =
               Games.preview_by_code(" #{String.downcase(session.join_code)} ")
    end

    test "sala lotada não está disponível" do
      session = game_session_fixture()
      for _seat <- 1..Games.max_participants(), do: participant_fixture(session)

      assert {:ok, %{available: false}} = Games.preview_by_code(session.join_code)
    end

    test "sala em andamento não está disponível" do
      session = game_session_fixture(%{status: :in_progress})

      assert {:ok, %{available: false}} = Games.preview_by_code(session.join_code)
    end

    test "sala encerrada e código inexistente respondem a mesma coisa" do
      cancelled = game_session_fixture(%{status: :cancelled})

      assert Games.preview_by_code(cancelled.join_code) == {:error, :not_found}
      assert Games.preview_by_code("ZZZZZZ") == {:error, :not_found}
      assert Games.preview_by_code("nada") == {:error, :not_found}
    end
  end

  describe "get_participant_of_session/2" do
    setup do
      session = game_session_fixture()

      {:ok, participant, token} =
        Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"})

      %{session: session, participant: participant, token: token}
    end

    test "encontra a participação daquela sala", context do
      %{session: session, participant: participant, token: token} = context

      assert {:ok, found} = Games.get_participant_of_session(token, session.join_code)
      assert found.id == participant.id
    end

    test "aceita o código em minúsculas", %{session: session, token: token} do
      assert {:ok, _participant} =
               Games.get_participant_of_session(token, String.downcase(session.join_code))
    end

    test "quem saiu continua sendo encontrado, porque a vaga é dele", context do
      %{session: session, participant: participant, token: token} = context
      {:ok, _participant} = Games.leave_game_session(participant)

      assert {:ok, _found} = Games.get_participant_of_session(token, session.join_code)
    end

    test "credencial de outra sala não vale aqui", %{token: token} do
      other = game_session_fixture()

      assert Games.get_participant_of_session(token, other.join_code) == {:error, :not_found}
    end

    test "credencial desconhecida, ausente ou malformada não encontra nada", %{session: session} do
      assert Games.get_participant_of_session(nil, session.join_code) == {:error, :not_found}
      assert Games.get_participant_of_session("", session.join_code) == {:error, :not_found}

      assert Games.get_participant_of_session("nao-e-base64!", session.join_code) ==
               {:error, :not_found}
    end

    test "a credencial morre com a sala", %{session: session, token: token} do
      {:ok, _session} = Games.expire_game_session(session)

      assert Games.get_participant_of_session(token, session.join_code) == {:error, :not_found}
    end
  end

  describe "get_session_by_participant_token/1" do
    setup do
      session = game_session_fixture()

      {:ok, participant, token} =
        Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"})

      %{session: session, participant: participant, token: token}
    end

    test "encontra a sala da credencial", %{session: session, token: token} do
      assert {:ok, found} = Games.get_session_by_participant_token(token)
      assert found.id == session.id
      assert found.join_code == session.join_code
    end

    test "continua encontrando a sala depois que ela é cancelada", context do
      %{session: session, token: token} = context
      _cancelled = close_session(session, :cancelled)

      assert {:ok, %GameSession{status: :cancelled}} =
               Games.get_session_by_participant_token(token)
    end

    test "distingue a sala expirada da cancelada", %{session: session, token: token} do
      {:ok, _session} = Games.expire_game_session(session)

      assert {:ok, %GameSession{status: :expired}} = Games.get_session_by_participant_token(token)
    end

    test "encontra a sala de quem saiu, porque a vaga continua reservada", context do
      %{session: session, participant: participant, token: token} = context
      {:ok, _participant} = Games.leave_game_session(participant)

      assert {:ok, found} = Games.get_session_by_participant_token(token)
      assert found.id == session.id
    end

    test "credencial desconhecida, ausente ou malformada não encontra nada" do
      assert Games.get_session_by_participant_token(nil) == {:error, :not_found}
      assert Games.get_session_by_participant_token("") == {:error, :not_found}
      assert Games.get_session_by_participant_token("nao-e-base64!") == {:error, :not_found}

      {unknown, _hash} = ParticipantToken.build()
      assert Games.get_session_by_participant_token(unknown) == {:error, :not_found}
    end
  end

  describe "suggested_nickname/1" do
    test "devolve nil para visitante" do
      assert Games.suggested_nickname(nil) == nil
    end

    test "devolve o nome da conta" do
      assert Games.suggested_nickname(user_scope_fixture()) == "Ana Souza"
    end

    test "aceita um nome curto" do
      scope = user_scope_fixture(user_fixture(%{name: "Jô"}))

      assert Games.suggested_nickname(scope) == "Jô"
    end

    test "trunca um nome acima de vinte caracteres" do
      scope = user_scope_fixture(user_fixture(%{name: "Maria Fernanda Albuquerque"}))
      suggestion = Games.suggested_nickname(scope)

      assert suggestion == "Maria Fernanda Albuq"
      assert String.length(suggestion) == 20
    end

    test "remove os caracteres que o apelido não aceita" do
      scope = user_scope_fixture(user_fixture(%{name: "Ana 🎉 Souza!"}))

      assert Games.suggested_nickname(scope) == "Ana  Souza"
    end

    test "devolve nil quando nada de aproveitável sobra" do
      scope = user_scope_fixture(user_fixture(%{name: "@@@"}))

      assert Games.suggested_nickname(scope) == nil
    end

    test "a sugestão é sempre aceita como apelido" do
      scope = user_scope_fixture(user_fixture(%{name: "Maria Fernanda Albuquerque"}))
      session = game_session_fixture(%{status: :waiting})

      assert {:ok, participant, _token} =
               Games.join_game_session(scope, session.join_code, %{
                 "nickname" => Games.suggested_nickname(scope)
               })

      assert participant.nickname == "Maria Fernanda Albuq"
    end
  end

  describe "leave_game_session/1" do
    setup :waiting_session

    test "marca a saída em left_at e released_at", %{session: session} do
      participant = participant_fixture(session)

      assert {:ok, left} = Games.leave_game_session(participant)

      assert %DateTime{} = left.left_at
      assert left.released_at == left.left_at

      persisted = Repo.get!(Participant, participant.id)
      assert persisted.left_at == left.left_at
      assert persisted.released_at == left.released_at
    end

    test "não devolve a vaga", %{session: session} do
      participant = participant_fixture(session)
      assert Games.reserved_slots(session) == 1

      assert {:ok, _left} = Games.leave_game_session(participant)

      assert Games.reserved_slots(session) == 1
    end

    test "mantém o apelido reservado à participação original", %{session: session} do
      participant = participant_fixture(session, %{nickname: "Ana"})

      assert {:ok, _left} = Games.leave_game_session(participant)

      assert {:error, :nickname_taken} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "ana"})
    end

    test "tira a participação da lista do lobby", %{host: host, session: session} do
      scope = user_scope_fixture(host)
      participant = participant_fixture(session)
      other = participant_fixture(session)

      assert {:ok, _left} = Games.leave_game_session(participant)

      assert {:ok, listed} = Games.list_participants(session, scope)
      assert Enum.map(listed, & &1.id) == [other.id]
    end

    test "perder o acesso não tira ninguém da lista do lobby", %{host: host, session: session} do
      scope = user_scope_fixture(host)
      participant = participant_fixture(session)

      assert {:ok, participant, first} = Games.claim_participant_connection(participant)
      assert {:ok, participant, _second} = Games.claim_participant_connection(participant)

      refute Games.connection_current?(participant, first)
      assert {:ok, [listed]} = Games.list_participants(session, scope)
      assert listed.id == participant.id
    end

    test "é idempotente", %{session: session} do
      participant = participant_fixture(session)

      assert {:ok, left} = Games.leave_game_session(participant)
      assert {:ok, again} = Games.leave_game_session(left)

      assert again.left_at == left.left_at
      assert again.released_at == left.released_at
    end

    test "é permitida em uma sala já encerrada" do
      session = game_session_fixture(%{status: :cancelled})
      participant = participant_fixture(session)

      assert {:ok, left} = Games.leave_game_session(participant)
      assert %DateTime{} = left.left_at
    end

    test "não altera quem a sala já liberou", %{session: session} do
      released_at = minutes_ago(10)
      participant = participant_fixture(session, %{released_at: released_at})

      assert {:ok, unchanged} = Games.leave_game_session(participant)

      assert is_nil(unchanged.left_at)
      assert unchanged.released_at == released_at
    end

    test "libera a pessoa para entrar em outra sala", %{session: session} do
      scope = user_scope_fixture()
      other_session = game_session_fixture(%{status: :waiting})

      assert {:ok, participant, _token} =
               Games.join_game_session(scope, session.join_code, %{"nickname" => "Ana"})

      assert {:ok, _left} = Games.leave_game_session(participant)

      assert {:ok, %Participant{}, _token} =
               Games.join_game_session(scope, other_session.join_code, %{"nickname" => "Ana"})
    end

    test "quem não saiu continua preso à sala", %{session: session} do
      scope = user_scope_fixture()
      other_session = game_session_fixture(%{status: :waiting})

      assert {:ok, _participant, _token} =
               Games.join_game_session(scope, session.join_code, %{"nickname" => "Ana"})

      assert {:error, :already_in_another_session} =
               Games.join_game_session(scope, other_session.join_code, %{"nickname" => "Ana"})
    end
  end

  describe "rejoin_game_session/2" do
    setup :waiting_session

    test "limpa left_at e released_at", %{session: session} do
      {participant, token} = join!(nil, session, "Ana")
      assert {:ok, _left} = Games.leave_game_session(participant)

      assert {:ok, back} = Games.rejoin_game_session(token)

      assert is_nil(back.left_at)
      assert is_nil(back.released_at)
      assert back.id == participant.id
    end

    test "devolve a participação à lista do lobby", %{host: host, session: session} do
      scope = user_scope_fixture(host)
      {participant, token} = join!(nil, session, "Ana")
      assert {:ok, _left} = Games.leave_game_session(participant)
      assert {:ok, []} = Games.list_participants(session, scope)

      assert {:ok, _back} = Games.rejoin_game_session(token)

      assert {:ok, [listed]} = Games.list_participants(session, scope)
      assert listed.id == participant.id
    end

    test "não altera o apelido nem o joined_at", %{session: session} do
      {participant, token} = join!(nil, session, "Ana")
      assert {:ok, _left} = Games.leave_game_session(participant)

      assert {:ok, back} = Games.rejoin_game_session(token)

      assert back.nickname == participant.nickname
      assert back.joined_at == participant.joined_at
    end

    test "não conta uma vaga nova", %{session: session} do
      {participant, token} = join!(nil, session, "Ana")
      assert {:ok, _left} = Games.leave_game_session(participant)

      assert {:ok, _back} = Games.rejoin_game_session(token)

      assert Games.reserved_slots(session) == 1
    end

    test "é aceito com a sala em andamento" do
      session = game_session_fixture(%{status: :waiting})
      {participant, token} = join!(nil, session, "Ana")
      assert {:ok, _left} = Games.leave_game_session(participant)
      start_session(session)

      assert {:ok, back} = Games.rejoin_game_session(token)
      assert back.id == participant.id
    end

    test "é aceito por quem nunca saiu", %{session: session} do
      {participant, token} = join!(nil, session, "Ana")

      assert {:ok, back} = Games.rejoin_game_session(token)

      assert back.id == participant.id
      assert is_nil(back.left_at)
    end

    test "é aceito mesmo com a sala lotada", %{session: session} do
      {participant, token} = join!(nil, session, "Ana")
      assert {:ok, _left} = Games.leave_game_session(participant)
      fill_session(session, Games.max_participants() - 1)
      assert Games.available_slots(session) == 0

      assert {:ok, back} = Games.rejoin_game_session(token)
      assert back.id == participant.id
    end

    test "é recusado em sala cancelada, expirada ou encerrada" do
      for status <- GameSession.closed_statuses() do
        session = game_session_fixture(%{status: :waiting})
        {_participant, token} = join!(nil, session, "Ana")
        close_session(session, status)

        assert {:error, :session_ended} = Games.rejoin_game_session(token)
      end
    end

    test "é recusado para um token malformado" do
      assert {:error, :not_found} = Games.rejoin_game_session("não é um token")
    end

    test "é recusado para um token inexistente" do
      {token, _hash} = ParticipantToken.build()

      assert {:error, :not_found} = Games.rejoin_game_session(token)
    end

    test "é recusado para a participação de uma sala excluída", %{session: session} do
      {_participant, token} = join!(nil, session, "Ana")
      Repo.delete!(session)

      assert {:error, :not_found} = Games.rejoin_game_session(token)
    end

    test "é recusado para quem entrou em outra sala", %{session: session} do
      scope = user_scope_fixture()
      other_session = game_session_fixture(%{status: :waiting})
      {participant, token} = join!(scope, session, "Ana")

      assert {:ok, _left} = Games.leave_game_session(participant)
      {_other, _other_token} = join!(scope, other_session, "Ana")

      assert {:error, :already_in_another_session} = Games.rejoin_game_session(token)
    end

    test "é recusado para quem passou a hospedar uma sala", %{session: session} do
      scope = user_scope_fixture()
      quiz = playable_quiz(scope)
      {participant, token} = join!(scope, session, "Ana")

      assert {:ok, _left} = Games.leave_game_session(participant)
      assert {:ok, _hosted} = Games.create_game_session(scope, quiz.id)

      assert {:error, :already_in_another_session} = Games.rejoin_game_session(token)
    end

    test "é recusado para o visitante que apresenta a credencial de outra sala", %{
      session: session
    } do
      other_session = game_session_fixture(%{status: :waiting})
      {participant, token} = join!(nil, session, "Ana")
      assert {:ok, _left} = Games.leave_game_session(participant)
      {_other, other_token} = join!(nil, other_session, "Ana")

      assert {:error, :already_in_another_session} =
               Games.rejoin_game_session(token, known_tokens: [other_token])
    end

    test "aceita o visitante que não apresenta a credencial da outra sala", %{session: session} do
      other_session = game_session_fixture(%{status: :waiting})
      {participant, token} = join!(nil, session, "Ana")
      assert {:ok, _left} = Games.leave_game_session(participant)
      {_other, _other_token} = join!(nil, other_session, "Ana")

      assert {:ok, back} = Games.rejoin_game_session(token)
      assert back.id == participant.id
    end

    test "ignora a própria credencial entre as apresentadas", %{session: session} do
      {participant, token} = join!(nil, session, "Ana")
      assert {:ok, _left} = Games.leave_game_session(participant)

      assert {:ok, back} = Games.rejoin_game_session(token, known_tokens: [token, "inválido"])
      assert back.id == participant.id
    end
  end

  describe "claim_participant_connection/1" do
    setup :waiting_session

    test "grava um connection_id novo a cada chamada", %{session: session} do
      participant = participant_fixture(session)

      assert {:ok, participant, first} = Games.claim_participant_connection(participant)
      assert {:ok, participant, second} = Games.claim_participant_connection(participant)

      refute first == second
      assert participant.connection_id == second
      assert Repo.get!(Participant, participant.id).connection_id == second
    end

    test "só o último acesso reivindicado é o corrente", %{session: session} do
      participant = participant_fixture(session)

      assert {:ok, participant, first} = Games.claim_participant_connection(participant)
      assert Games.connection_current?(participant, first)

      assert {:ok, participant, second} = Games.claim_participant_connection(participant)

      assert Games.connection_current?(participant, second)
      refute Games.connection_current?(participant, first)
    end

    test "nenhum acesso é corrente antes da primeira reivindicação", %{session: session} do
      participant = participant_fixture(session)

      refute Games.connection_current?(participant, Ecto.UUID.generate())
      refute Games.connection_current?(participant, nil)
    end

    test "não cria participação nova nem muda a contagem de vagas", %{session: session} do
      participant = participant_fixture(session, %{nickname: "Ana"})
      fill_session(session, 2)

      assert {:ok, transferred, _connection_id} =
               Games.claim_participant_connection(participant)

      assert transferred.id == participant.id
      assert transferred.nickname == "Ana"
      assert Games.reserved_slots(session) == 3
      assert Repo.aggregate(participants_of(session), :count) == 3
    end

    test "a transferência preserva a presença no lobby", %{host: host, session: session} do
      scope = user_scope_fixture(host)
      participant = participant_fixture(session)

      assert {:ok, transferred, _connection_id} =
               Games.claim_participant_connection(participant)

      assert {:ok, [listed]} = Games.list_participants(session, scope)
      assert listed.id == transferred.id
    end
  end

  describe "claim_host_connection/2" do
    setup :waiting_session

    test "o host assume o controle da sala", %{host: host, session: session} do
      scope = user_scope_fixture(host)

      assert {:ok, held, connection_id} = Games.claim_host_connection(scope, session)

      assert held.host_connection_id == connection_id
      assert Games.host_connection_current?(held, connection_id)
      assert Repo.get!(GameSession, session.id).host_connection_id == connection_id
    end

    test "a aba anterior deixa de ter o acesso válido", %{host: host, session: session} do
      scope = user_scope_fixture(host)

      assert {:ok, held, first} = Games.claim_host_connection(scope, session)
      assert {:ok, held, second} = Games.claim_host_connection(scope, held)

      assert Games.host_connection_current?(held, second)
      refute Games.host_connection_current?(held, first)
    end

    test "nenhum acesso é corrente antes da primeira reivindicação", %{session: session} do
      refute Games.host_connection_current?(session, Ecto.UUID.generate())
      refute Games.host_connection_current?(session, nil)
    end

    test "outra pessoa recebe :unauthorized", %{session: session} do
      assert {:error, :unauthorized} =
               Games.claim_host_connection(user_scope_fixture(), session)

      assert is_nil(Repo.get!(GameSession, session.id).host_connection_id)
    end

    test "a transferência não encerra a sessão de conta do aparelho anterior", %{
      host: host,
      session: session
    } do
      scope = user_scope_fixture(host)
      account_token = Accounts.generate_user_session_token(host)

      assert {:ok, held, _first} = Games.claim_host_connection(scope, session)
      assert {:ok, _held, _second} = Games.claim_host_connection(scope, held)

      assert {%User{id: id}, _authenticated_at} =
               Accounts.get_user_by_session_token(account_token)

      assert id == host.id
    end
  end

  describe "saída, retorno e transferência sob concorrência" do
    setup :waiting_session

    test "dez reivindicações da mesma participação deixam um único acesso corrente", %{
      session: session
    } do
      participant = participant_fixture(session)

      results =
        in_parallel(1..10, fn _index -> Games.claim_participant_connection(participant) end)

      connection_ids =
        Enum.map(results, fn result ->
          assert {:ok, %Participant{}, connection_id} = result
          connection_id
        end)

      assert connection_ids |> MapSet.new() |> MapSet.size() == 10

      current = Repo.get!(Participant, participant.id)
      assert Enum.count(connection_ids, &Games.connection_current?(current, &1)) == 1
      assert Repo.aggregate(participants_of(session), :count) == 1
    end

    test "retorno a uma sala e entrada em outra produzem um único sucesso", %{session: session} do
      scope = user_scope_fixture()
      other_session = game_session_fixture(%{status: :waiting})
      {participant, token} = join!(scope, session, "Ana")
      assert {:ok, _left} = Games.leave_game_session(participant)

      [rejoined, joined] =
        in_parallel([:rejoin, :join], fn
          :rejoin ->
            Games.rejoin_game_session(token)

          :join ->
            Games.join_game_session(scope, other_session.join_code, %{"nickname" => "Ana"})
        end)

      successes =
        Enum.count(
          [rejoined, joined],
          &(match?({:ok, %Participant{}}, &1) or match?({:ok, %Participant{}, _token}, &1))
        )

      assert successes == 1
      assert Repo.aggregate(active_participations_of(scope), :count) == 1
    end
  end

  describe "regressão de capacidade" do
    setup :waiting_session

    test "sair e voltar conta uma única vez na capacidade", %{session: session} do
      {participant, token} = join!(nil, session, "Ana")

      assert {:ok, _left} = Games.leave_game_session(participant)
      assert {:ok, _back} = Games.rejoin_game_session(token)
      assert {:ok, _left_again} = Games.leave_game_session(participant)
      assert {:ok, _back_again} = Games.rejoin_game_session(token)

      assert Games.reserved_slots(session) == 1
      assert Games.available_slots(session) == Games.max_participants() - 1
      assert Repo.aggregate(participants_of(session), :count) == 1
    end
  end

  describe "start_game_session/3" do
    setup :hosted_waiting_session

    test "inicia a sala com um participante conectado", %{scope: scope, session: session} do
      participant_fixture(session)

      assert {:ok, started} = Games.start_game_session(scope, session, 1)

      assert started.status == :in_progress
      assert started.started_at

      assert Repo.get!(GameSession, session.id).status == :in_progress
    end

    test "inicia a sala com a lotação inteira conectada", %{scope: scope, session: session} do
      fill_session(session, Games.max_participants())

      assert {:ok, started} = Games.start_game_session(scope, session, Games.max_participants())

      assert started.status == :in_progress
    end

    test "recusa iniciar sem ninguém conectado", %{scope: scope, session: session} do
      assert {:error, :no_connected_participants} = Games.start_game_session(scope, session, 0)

      current = Repo.get!(GameSession, session.id)
      assert current.status == :waiting
      assert is_nil(current.started_at)
    end

    test "recusa iniciar com todos os inscritos desconectados", %{
      scope: scope,
      session: session
    } do
      fill_session(session, 3)

      assert {:error, :no_connected_participants} = Games.start_game_session(scope, session, 0)
      assert Repo.get!(GameSession, session.id).status == :waiting
    end

    test "recusa iniciar quando o único inscrito saiu", %{scope: scope, session: session} do
      {participant, _token} = join!(nil, session, "Ana")
      assert {:ok, _left} = Games.leave_game_session(participant)

      assert {:error, :no_connected_participants} = Games.start_game_session(scope, session, 0)
      assert Repo.get!(GameSession, session.id).status == :waiting
    end

    test "recusa que um participante inicie a sala", %{session: session} do
      participant_scope = user_scope_fixture()
      participant_fixture(session, %{user: participant_scope.user})

      assert {:error, :unauthorized} = Games.start_game_session(participant_scope, session, 1)
      assert Repo.get!(GameSession, session.id).status == :waiting
      assert Games.snapshot_question_count(session) == 0
    end

    test "recusa que um terceiro autenticado inicie a sala", %{session: session} do
      assert {:error, :unauthorized} = Games.start_game_session(user_scope_fixture(), session, 1)
      assert Repo.get!(GameSession, session.id).status == :waiting
      assert Games.snapshot_question_count(session) == 0
    end

    test "recusa reabrir uma sala finalizada", %{scope: scope, session: session} do
      finished = close_session(session, :finished)

      assert {:error, :invalid_transition} = Games.start_game_session(scope, finished, 1)
      assert Repo.get!(GameSession, session.id).status == :finished
      assert Games.snapshot_question_count(session) == 0
    end

    test "devolve a partida quando o host inicia de novo", %{scope: scope, session: session} do
      participant_fixture(session)
      assert {:ok, started} = Games.start_game_session(scope, session, 1)

      assert {:ok, again} = Games.start_game_session(scope, started, 1)

      assert again.id == started.id
      assert again.started_at == started.started_at
      assert Repo.get!(GameSession, session.id).started_at == started.started_at
    end

    test "recusa que um terceiro inicie uma sala já iniciada", %{
      scope: scope,
      session: session
    } do
      participant_fixture(session)
      assert {:ok, started} = Games.start_game_session(scope, session, 1)

      assert {:error, :unauthorized} =
               Games.start_game_session(user_scope_fixture(), started, 1)
    end

    test "recusa reabrir uma sala cancelada", %{scope: scope, session: session} do
      cancelled = close_session(session, :cancelled)

      assert {:error, :invalid_transition} = Games.start_game_session(scope, cancelled, 1)
      assert Repo.get!(GameSession, session.id).status == :cancelled
    end

    test "recusa reabrir uma sala expirada", %{scope: scope, session: session} do
      expired = close_session(session, :expired)

      assert {:error, :invalid_transition} = Games.start_game_session(scope, expired, 1)
      assert Repo.get!(GameSession, session.id).status == :expired
    end

    test "bloqueia novas inscrições depois do início", %{scope: scope, session: session} do
      participant_fixture(session)

      assert {:ok, started} = Games.start_game_session(scope, session, 1)

      assert {:error, :session_not_joinable} =
               Games.join_game_session(nil, started.join_code, %{"nickname" => "Bia"})
    end

    test "quem já estava inscrito ainda volta depois do início", %{
      scope: scope,
      session: session
    } do
      {participant, token} = join!(nil, session, "Ana")

      assert {:ok, _started} = Games.start_game_session(scope, session, 1)

      assert {:ok, back} = Games.rejoin_game_session(token)
      assert back.id == participant.id
    end
  end

  describe "start_game_session/3 e o congelamento do quiz" do
    test "congela perguntas, alternativas e gabarito na ordem do quiz" do
      %{scope: scope, quiz: quiz, session: session} = room_with_questions(3)

      assert {:ok, started} = Games.start_game_session(scope, session, 1)

      assert started.status == :in_progress
      assert started.started_at

      questions = Games.list_snapshot_questions(started)

      assert Enum.map(questions, & &1.position) == [1, 2, 3]

      assert Enum.map(questions, & &1.question_text) == [
               "Pergunta 1 do quiz",
               "Pergunta 2 do quiz",
               "Pergunta 3 do quiz"
             ]

      assert Enum.map(questions, & &1.question_id) == question_ids(quiz)
      assert length(Enum.flat_map(questions, & &1.answer_options)) == 12

      for question <- questions do
        assert Enum.map(question.answer_options, & &1.position) == [1, 2, 3, 4]

        assert Enum.map(question.answer_options, & &1.text) == [
                 "Brasília",
                 "Rio de Janeiro",
                 "São Paulo",
                 "Salvador"
               ]

        assert Enum.map(question.answer_options, & &1.is_correct) == [true, false, false, false]
        assert Enum.all?(question.answer_options, & &1.original_answer_option_id)
      end
    end

    test "congela um quiz de uma única pergunta" do
      %{scope: scope, session: session} = room_with_questions(1)

      assert {:ok, started} = Games.start_game_session(scope, session, 1)

      assert Games.snapshot_question_count(started) == 1
      assert [%{position: 1, answer_options: options}] = Games.list_snapshot_questions(started)
      assert length(options) == 4
    end

    test "congela um quiz de vinte perguntas" do
      %{scope: scope, session: session} = room_with_questions(20)

      assert {:ok, started} = Games.start_game_session(scope, session, 1)

      questions = Games.list_snapshot_questions(started)

      assert Enum.map(questions, & &1.position) == Enum.to_list(1..20)
      assert length(Enum.flat_map(questions, & &1.answer_options)) == 80
    end

    test "renumera as posições de 1 a n quando o quiz tem buracos" do
      scope = user_scope_fixture()
      quiz = quiz_fixture(scope)
      first = question_fixture(scope, quiz, %{text: "Pergunta que ficou"})
      second = question_fixture(scope, quiz, %{text: "Pergunta que saiu"})
      third = question_fixture(scope, quiz, %{text: "Pergunta do fim"})
      Repo.delete!(second)

      session = room_for(scope, quiz)

      assert {:ok, started} = Games.start_game_session(scope, session, 1)

      assert Enum.map(Games.list_snapshot_questions(started), &{&1.position, &1.question_id}) ==
               [{1, first.id}, {2, third.id}]
    end

    test "preserva o gabarito quando a correta é a última alternativa" do
      scope = user_scope_fixture()
      quiz = quiz_fixture(scope)

      question_fixture(scope, quiz, %{
        answer_options: [
          %{text: "Rio de Janeiro", position: 1, is_correct: false},
          %{text: "São Paulo", position: 2, is_correct: false},
          %{text: "Salvador", position: 3, is_correct: false},
          %{text: "Brasília", position: 4, is_correct: true}
        ]
      })

      session = room_for(scope, quiz)

      assert {:ok, started} = Games.start_game_session(scope, session, 1)

      assert [%{answer_options: options}] = Games.list_snapshot_questions(started)
      assert Enum.map(options, & &1.is_correct) == [false, false, false, true]
      assert List.last(Enum.map(options, & &1.text)) == "Brasília"
    end

    test "o snapshot não muda quando o quiz é editado depois" do
      %{scope: scope, quiz: quiz, session: session} = room_with_questions(2)

      assert {:ok, started} = Games.start_game_session(scope, session, 1)

      [first_id | _rest] = question_ids(quiz)

      Repo.update_all(from(q in Question, where: q.id == ^first_id),
        set: [text: "Enunciado trocado depois do início"]
      )

      Repo.update_all(from(o in AnswerOption, where: o.question_id == ^first_id),
        set: [text: "Alternativa trocada"]
      )

      assert {:ok, frozen} = Games.get_snapshot_question(started, 1)
      assert frozen.question_text == "Pergunta 1 do quiz"
      assert List.first(Enum.map(frozen.answer_options, & &1.text)) == "Brasília"
    end

    test "a falha ao gravar as alternativas não deixa partida iniciada nem snapshot" do
      %{scope: scope, session: session} = room_with_questions(2)

      # A `CHECK (false)` posta no meio do congelamento é a forma de reproduzir
      # o que a aplicação nunca provoca sozinha: a segunda inserção falhando
      # depois de a primeira ter escrito. Ela desaparece com a transação do
      # sandbox no fim do teste.
      Repo.query!(
        "ALTER TABLE game_session_answer_options ADD CONSTRAINT falha_forcada CHECK (false) NOT VALID"
      )

      assert_raise Postgrex.Error, fn -> Games.start_game_session(scope, session, 1) end

      current = Repo.get!(GameSession, session.id)
      assert current.status == :waiting
      assert is_nil(current.started_at)
      assert Games.snapshot_question_count(current) == 0
    end

    test "iniciar de novo não duplica o snapshot" do
      %{scope: scope, session: session} = room_with_questions(3)

      assert {:ok, started} = Games.start_game_session(scope, session, 1)
      assert {:ok, again} = Games.start_game_session(scope, started, 1)

      assert again.started_at == started.started_at
      assert Games.snapshot_question_count(again) == 3

      assert length(Enum.flat_map(Games.list_snapshot_questions(again), & &1.answer_options)) ==
               12
    end

    test "recusa iniciar quando o quiz foi removido do banco" do
      %{scope: scope, quiz: quiz, session: session} = room_with_questions(2)

      Repo.delete!(quiz)

      assert {:error, :quiz_unavailable} = Games.start_game_session(scope, session, 1)

      current = Repo.get!(GameSession, session.id)
      assert current.status == :waiting
      assert is_nil(current.started_at)
      assert Games.snapshot_question_count(current) == 0
    end

    test "recusa congelar um quiz que não é do host" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      quiz = playable_quiz(other_scope)
      session = game_session_fixture(%{host: scope.user, quiz: quiz, status: :waiting})
      participant_fixture(session)

      assert {:error, :quiz_unavailable} = Games.start_game_session(scope, session, 1)

      assert Repo.get!(GameSession, session.id).status == :waiting
      assert Games.snapshot_question_count(session) == 0
    end

    test "recusa iniciar quando o quiz perdeu todas as perguntas" do
      %{scope: scope, quiz: quiz, session: session} = room_with_questions(2)

      Repo.delete_all(from q in Question, where: q.quiz_id == ^quiz.id)

      assert {:error, :quiz_not_playable} = Games.start_game_session(scope, session, 1)

      assert Repo.get!(GameSession, session.id).status == :waiting
      assert Games.snapshot_question_count(session) == 0
    end

    test "o começo é publicado uma única vez, com o snapshot já gravado" do
      %{scope: scope, session: session} = room_with_questions(3)
      :ok = Games.subscribe(session.id)

      assert {:ok, started} = Games.start_game_session(scope, session, 1)

      assert_receive {:game_started, %GameSession{id: id} = published}
      assert id == started.id
      assert Games.snapshot_question_count(published) == 3

      assert {:ok, _again} = Games.start_game_session(scope, started, 1)
      refute_receive {:game_started, _session}, 50
    end
  end

  describe "leitura do snapshot" do
    setup do
      %{scope: scope, quiz: quiz, session: session} = room_with_questions(3)
      assert {:ok, started} = Games.start_game_session(scope, session, 1)

      %{scope: scope, quiz: quiz, session: started}
    end

    test "list_snapshot_questions/1 devolve tudo em ordem com as alternativas", %{
      session: session
    } do
      questions = Games.list_snapshot_questions(session)

      assert Enum.map(questions, & &1.position) == [1, 2, 3]

      for question <- questions do
        assert Enum.map(question.answer_options, & &1.position) == [1, 2, 3, 4]
      end
    end

    test "list_snapshot_questions/1 devolve lista vazia para uma sala no lobby" do
      %{session: waiting} = room_with_questions(2)

      assert Games.list_snapshot_questions(waiting) == []
      assert Games.snapshot_question_count(waiting) == 0
    end

    test "get_snapshot_question/2 encontra a pergunta da posição", %{session: session} do
      assert {:ok, question} = Games.get_snapshot_question(session, 2)

      assert question.position == 2
      assert question.question_text == "Pergunta 2 do quiz"
      assert length(question.answer_options) == 4
    end

    test "get_snapshot_question/2 recusa uma posição inexistente", %{session: session} do
      assert {:error, :not_found} = Games.get_snapshot_question(session, 0)
      assert {:error, :not_found} = Games.get_snapshot_question(session, 4)
      assert {:error, :not_found} = Games.get_snapshot_question(session, 99)
    end

    test "get_snapshot_question/2 não enxerga a pergunta de outra partida", %{session: session} do
      %{scope: other_scope, session: other} = room_with_questions(3)
      assert {:ok, other_started} = Games.start_game_session(other_scope, other, 1)

      assert {:ok, mine} = Games.get_snapshot_question(session, 1)
      assert {:ok, theirs} = Games.get_snapshot_question(other_started, 1)

      refute mine.id == theirs.id
    end

    test "snapshot_question_count/1 conta as perguntas congeladas", %{session: session} do
      assert Games.snapshot_question_count(session) == 3
    end

    test "a leitura continua inteira depois que o quiz é excluído", %{
      quiz: quiz,
      session: session
    } do
      Repo.delete!(quiz)

      questions = Games.list_snapshot_questions(session)

      assert Enum.map(questions, & &1.position) == [1, 2, 3]
      assert List.first(Enum.map(questions, & &1.question_text)) == "Pergunta 1 do quiz"
      assert Enum.all?(questions, &is_nil(&1.question_id))
      assert length(Enum.flat_map(questions, & &1.answer_options)) == 12
      assert {:ok, %{position: 1}} = Games.get_snapshot_question(session, 1)
      assert Games.snapshot_question_count(session) == 3
    end

    test "nenhuma leitura do snapshot consulta as tabelas de quizzes", %{session: session} do
      refute_quiz_tables_queried(fn ->
        Games.list_snapshot_questions(session)
        Games.get_snapshot_question(session, 1)
        Games.snapshot_question_count(session)
      end)
    end
  end

  describe "create_game_session/3 e a duração das perguntas" do
    test "usa trinta segundos quando a duração não é informada" do
      scope = user_scope_fixture()
      quiz = playable_quiz(scope)

      assert {:ok, session} = Games.create_game_session(scope, quiz.id)

      assert session.question_duration_seconds == 30
      assert Repo.get!(GameSession, session.id).question_duration_seconds == 30
    end

    test "aceita cada uma das durações disponíveis" do
      for duration <- GameSession.question_durations() do
        scope = user_scope_fixture()
        quiz = playable_quiz(scope)

        assert {:ok, session} =
                 Games.create_game_session(scope, quiz.id, %{
                   question_duration_seconds: duration
                 })

        assert session.question_duration_seconds == duration
        assert Repo.get!(GameSession, session.id).question_duration_seconds == duration
      end
    end

    test "aceita a duração vinda de um formulário, com chave em texto" do
      scope = user_scope_fixture()
      quiz = playable_quiz(scope)

      assert {:ok, session} =
               Games.create_game_session(scope, quiz.id, %{
                 "question_duration_seconds" => "60"
               })

      assert session.question_duration_seconds == 60
    end

    test "recusa uma duração fora da lista e não abre a sala" do
      for duration <- [45, 15, 0] do
        scope = user_scope_fixture()
        quiz = playable_quiz(scope)

        assert {:error, changeset} =
                 Games.create_game_session(scope, quiz.id, %{
                   question_duration_seconds: duration
                 })

        assert errors_on(changeset).question_duration_seconds == [
                 "escolha uma das durações disponíveis"
               ]

        refute hosted_any?(scope)
      end
    end

    test "uma duração em branco cai no padrão" do
      scope = user_scope_fixture()
      quiz = playable_quiz(scope)

      assert {:ok, session} =
               Games.create_game_session(scope, quiz.id, %{"question_duration_seconds" => ""})

      assert session.question_duration_seconds == 30
    end

    test "ignora qualquer outra chave enviada junto" do
      scope = user_scope_fixture()
      quiz = playable_quiz(scope)

      assert {:ok, session} =
               Games.create_game_session(scope, quiz.id, %{
                 "quiz_title" => "Título inventado",
                 "status" => "in_progress",
                 "question_duration_seconds" => 20
               })

      assert session.quiz_title == quiz.title
      assert session.status == :waiting
      assert session.question_duration_seconds == 20
    end
  end

  describe "cancel_game_session/2" do
    setup :hosted_waiting_session

    test "cancela a sala no lobby", %{scope: scope, session: session} do
      assert {:ok, cancelled} = Games.cancel_game_session(scope, session)

      assert cancelled.status == :cancelled
      assert cancelled.finished_at
      assert Repo.get!(GameSession, session.id).status == :cancelled
    end

    test "cancela a sala depois do início, preservando o começo", %{
      scope: scope,
      session: session
    } do
      started = start_session(session)

      assert {:ok, cancelled} = Games.cancel_game_session(scope, started)

      assert cancelled.status == :cancelled
      assert cancelled.started_at == started.started_at
      assert cancelled.finished_at
    end

    test "libera as participações presas sem marcar saída", %{scope: scope, session: session} do
      present = participant_fixture(session)
      gone = participant_fixture(session, %{left_at: minutes_ago(1), released_at: minutes_ago(1)})

      assert {:ok, _cancelled} = Games.cancel_game_session(scope, session)

      present = Repo.get!(Participant, present.id)
      assert present.released_at
      assert is_nil(present.left_at)

      released_gone = Repo.get!(Participant, gone.id)
      assert released_gone.released_at == gone.released_at
      assert released_gone.left_at == gone.left_at
    end

    test "libera os participantes para entrar em outra sala", %{scope: scope, session: session} do
      participant_scope = user_scope_fixture()
      participant_fixture(session, %{user: participant_scope.user})

      assert {:ok, _cancelled} = Games.cancel_game_session(scope, session)
      refute Games.engaged_in_session?(participant_scope)

      other = game_session_fixture(%{status: :waiting})

      assert {:ok, _participant, _token} =
               Games.join_game_session(participant_scope, other.join_code, %{"nickname" => "Ana"})
    end

    test "libera o host para abrir outra sala, com outro código", %{
      scope: scope,
      session: session,
      quiz: quiz
    } do
      assert {:ok, _cancelled} = Games.cancel_game_session(scope, session)

      assert {:ok, reopened} = Games.create_game_session(scope, quiz.id)
      assert reopened.id != session.id
      assert reopened.join_code != session.join_code
    end

    test "recusa que um participante cancele", %{session: session} do
      participant_scope = user_scope_fixture()
      participant_fixture(session, %{user: participant_scope.user})

      assert {:error, :unauthorized} = Games.cancel_game_session(participant_scope, session)
      assert Repo.get!(GameSession, session.id).status == :waiting
    end

    test "recusa que um terceiro autenticado cancele", %{session: session} do
      assert {:error, :unauthorized} = Games.cancel_game_session(user_scope_fixture(), session)
      assert Repo.get!(GameSession, session.id).status == :waiting
    end

    test "recusa cancelar uma sala já encerrada", %{scope: scope, session: session} do
      cancelled = close_session(session, :cancelled)

      assert {:error, :invalid_transition} = Games.cancel_game_session(scope, cancelled)
    end
  end

  describe "expire_game_session/1" do
    setup :hosted_waiting_session

    test "expira uma sala em espera", %{session: session} do
      assert {:ok, expired} = Games.expire_game_session(session)

      assert expired.status == :expired
      assert expired.finished_at
      assert is_nil(expired.expires_at)
    end

    test "expira uma sala em andamento", %{session: session} do
      started = start_session(session)

      assert {:ok, expired} = Games.expire_game_session(started)

      assert expired.status == :expired
      assert expired.started_at == started.started_at
    end

    test "libera as participações ao expirar", %{session: session} do
      participant = participant_fixture(session)

      assert {:ok, _expired} = Games.expire_game_session(session)

      participant = Repo.get!(Participant, participant.id)
      assert participant.released_at
      assert is_nil(participant.left_at)
    end

    test "libera o host ao expirar", %{scope: scope, session: session, quiz: quiz} do
      assert {:ok, _expired} = Games.expire_game_session(session)

      assert {:ok, _reopened} = Games.create_game_session(scope, quiz.id)
    end

    test "recusa expirar uma sala já encerrada", %{session: session} do
      cancelled = close_session(session, :cancelled)

      assert {:error, :invalid_transition} = Games.expire_game_session(cancelled)
      assert Repo.get!(GameSession, session.id).status == :cancelled
    end
  end

  describe "ausência do host" do
    setup :hosted_waiting_session

    test "a queda preserva a sala e agenda o prazo", %{session: session} do
      at = now()

      assert {:ok, away} = Games.mark_host_disconnected(session, at)

      assert away.status == :waiting
      assert away.host_disconnected_at == at
      assert away.expires_at == DateTime.add(at, Games.host_absence_timeout(), :second)
      assert Games.host_absence_timeout() == 300
    end

    test "o prazo vale igualmente para a sala em andamento", %{session: session} do
      at = now()
      started = start_session(session)

      assert {:ok, away} = Games.mark_host_disconnected(started, at)

      assert away.status == :in_progress
      assert away.expires_at == DateTime.add(at, Games.host_absence_timeout(), :second)
    end

    test "uma nova queda não estende o prazo em curso", %{session: session} do
      assert {:ok, away} = Games.mark_host_disconnected(session, minutes_ago(3))

      assert {:ok, again} = Games.mark_host_disconnected(session, now())

      assert again.host_disconnected_at == away.host_disconnected_at
      assert again.expires_at == away.expires_at
    end

    test "o retorno do host limpa a queda e o prazo", %{session: session} do
      assert {:ok, away} = Games.mark_host_disconnected(session, minutes_ago(2))

      assert {:ok, back} = Games.mark_host_connected(away)

      assert is_nil(back.host_disconnected_at)
      assert is_nil(back.expires_at)
      assert Games.seconds_until_expiration(back, now()) == nil
    end

    test "uma ausência depois do retorno vale cinco minutos cheios", %{session: session} do
      assert {:ok, away} = Games.mark_host_disconnected(session, minutes_ago(4))
      assert {:ok, back} = Games.mark_host_connected(away)

      at = now()
      assert {:ok, away_again} = Games.mark_host_disconnected(back, at)

      assert away_again.expires_at == DateTime.add(at, Games.host_absence_timeout(), :second)
      assert Games.seconds_until_expiration(away_again, at) == Games.host_absence_timeout()
    end

    test "o retorno de um host que nunca caiu não altera a sala", %{session: session} do
      assert {:ok, unchanged} = Games.mark_host_connected(session)

      assert is_nil(unchanged.host_disconnected_at)
      assert unchanged.updated_at == session.updated_at
    end

    test "uma sala encerrada não ganha prazo de expiração", %{session: session} do
      cancelled = close_session(session, :cancelled)

      assert {:ok, unchanged} = Games.mark_host_disconnected(cancelled, now())

      assert unchanged.status == :cancelled
      assert is_nil(unchanged.host_disconnected_at)
      assert is_nil(unchanged.expires_at)
    end
  end

  describe "seconds_until_expiration/2" do
    test "conta o que falta para o prazo vencer" do
      at = now()
      away = expiring_session(:waiting, at)

      assert Games.seconds_until_expiration(away, DateTime.add(at, 60, :second)) ==
               Games.host_absence_timeout() - 60
    end

    test "devolve nil quando não há prazo em curso" do
      assert Games.seconds_until_expiration(game_session_fixture(), now()) == nil
    end

    test "devolve zero para um prazo já vencido" do
      away = expiring_session(:waiting, minutes_ago(30))

      assert Games.seconds_until_expiration(away, now()) == 0
    end
  end

  describe "list_expired_sessions/1" do
    test "devolve apenas as salas ativas com prazo vencido" do
      overdue_waiting = expiring_session(:waiting, minutes_ago(6))
      overdue_running = expiring_session(:in_progress, minutes_ago(6))
      _still_in_time = expiring_session(:waiting, now())
      _no_deadline = game_session_fixture(%{status: :waiting})

      ids = Enum.map(Games.list_expired_sessions(now()), & &1.id)

      assert Enum.sort(ids) == Enum.sort([overdue_waiting.id, overdue_running.id])
    end

    test "ignora as salas já encerradas, mesmo com prazo vencido" do
      cancelled = closed_session_with_deadline(:cancelled, minutes_ago(10))
      expired = closed_session_with_deadline(:expired, minutes_ago(10))

      assert Games.list_expired_sessions(now()) == []
      assert Repo.get!(GameSession, cancelled.id).status == :cancelled
      assert Repo.get!(GameSession, expired.id).status == :expired
    end

    test "expira, na primeira varredura, o prazo vencido enquanto a aplicação esteve fora" do
      away = expiring_session(:waiting, minutes_ago(35))
      participant = participant_fixture(away)

      assert [found] = Games.list_expired_sessions(now())
      assert found.id == away.id
      assert found.expires_at == away.expires_at

      assert {:ok, expired} = Games.expire_game_session(found)
      assert expired.status == :expired

      assert Games.list_expired_sessions(now()) == []
      assert Repo.get!(Participant, participant.id).released_at
    end
  end

  describe "encerramento e início sob concorrência" do
    setup :hosted_waiting_session

    test "host e varredura encerrando juntos produzem um único encerramento", %{
      scope: scope,
      session: session
    } do
      assert {:ok, away} = Games.mark_host_disconnected(session, minutes_ago(6))
      participant_fixture(away)

      results =
        in_parallel([:cancel, :expire], fn
          :cancel -> Games.cancel_game_session(scope, away)
          :expire -> Games.expire_game_session(away)
        end)

      assert Enum.count(results, &match?({:ok, %GameSession{}}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :invalid_transition})) == 1

      current = Repo.get!(GameSession, session.id)
      assert current.status in [:cancelled, :expired]
      assert current.finished_at
      assert is_nil(current.expires_at)
    end

    test "duas chamadas de início produzem um único started_at e um único snapshot", %{
      scope: scope,
      session: session
    } do
      participant_fixture(session)

      results =
        in_parallel([1, 2], fn _attempt -> Games.start_game_session(scope, session, 1) end)

      assert [{:ok, %GameSession{} = first}, {:ok, %GameSession{} = second}] = results
      assert first.started_at == second.started_at

      current = Repo.get!(GameSession, session.id)
      assert current.status == :in_progress
      assert current.started_at == first.started_at
      assert Games.snapshot_question_count(current) == 1
    end

    test "dois inícios simultâneos publicam o começo uma única vez", %{
      scope: scope,
      session: session
    } do
      participant_fixture(session)
      :ok = Games.subscribe(session.id)

      in_parallel([1, 2], fn _attempt -> Games.start_game_session(scope, session, 1) end)

      assert_receive {:game_started, %GameSession{}}
      refute_receive {:game_started, _session}, 50
    end
  end

  defp join!(scope, session, nickname) do
    assert {:ok, participant, token} =
             Games.join_game_session(scope, session.join_code, %{"nickname" => nickname})

    {participant, token}
  end

  describe "topic/1, session_id_from_topic/1 e subscribe/1" do
    setup :waiting_session

    test "o tópico é o da sala", %{session: session} do
      assert Games.topic(session.id) == "game_session:#{session.id}"
    end

    test "o tópico volta a ser o id da sala", %{session: session} do
      assert Games.session_id_from_topic(Games.topic(session.id)) == {:ok, session.id}
    end

    test "um tópico que não é de sala é recusado" do
      assert Games.session_id_from_topic("game_session:abc") == :error
      assert Games.session_id_from_topic("game_session:1x") == :error
      assert Games.session_id_from_topic("outra_coisa:1") == :error
      assert Games.session_id_from_topic("") == :error
    end

    test "o inscrito recebe os eventos da sala", %{session: session} do
      assert :ok = Games.subscribe(session.id)

      assert {:ok, participant, _token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"})

      assert_receive {:participant_joined, %Participant{id: id}}
      assert id == participant.id
    end

    test "quem não se inscreveu não recebe nada", %{session: session} do
      other_session = game_session_fixture(%{status: :waiting})
      assert :ok = Games.subscribe(other_session.id)

      assert {:ok, _participant, _token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"})

      refute_receive {:participant_joined, _participant}, 50
    end
  end

  describe "eventos de entrada, saída e retorno" do
    setup :waiting_session

    test "a entrada é publicada depois do commit", %{session: session} do
      :ok = Games.subscribe(session.id)

      assert {:ok, participant, _token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"})

      assert_receive {:participant_joined, %Participant{} = announced}
      assert announced.id == participant.id
      assert announced.nickname == "Ana"

      # O evento só vale se quem for ao banco por causa dele encontrar a linha.
      assert Repo.get(Participant, announced.id)
    end

    test "a entrada recusada não publica nada", %{session: session} do
      :ok = Games.subscribe(session.id)

      assert {:error, :session_not_found} =
               Games.join_game_session(nil, "ZZZZZZ", %{"nickname" => "Ana"})

      assert {:error, %Ecto.Changeset{}} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "A"})

      refute_receive {:participant_joined, _participant}, 50
    end

    test "o apelido tomado não publica nada", %{session: session} do
      participant_fixture(session, %{nickname: "Ana"})
      :ok = Games.subscribe(session.id)

      assert {:error, :nickname_taken} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "ana"})

      refute_receive {:participant_joined, _participant}, 50
    end

    test "a saída é publicada", %{session: session} do
      participant = participant_fixture(session)
      :ok = Games.subscribe(session.id)

      assert {:ok, left} = Games.leave_game_session(participant)

      assert_receive {:participant_left, %Participant{id: id}}
      assert id == left.id
    end

    test "sair de novo não publica outra vez", %{session: session} do
      participant = participant_fixture(session, %{left_at: now(), released_at: now()})
      :ok = Games.subscribe(session.id)

      assert {:ok, _unchanged} = Games.leave_game_session(participant)

      refute_receive {:participant_left, _participant}, 50
    end

    test "o retorno é publicado", %{session: session} do
      assert {:ok, participant, token} =
               Games.join_game_session(nil, session.join_code, %{"nickname" => "Ana"})

      assert {:ok, _left} = Games.leave_game_session(participant)
      :ok = Games.subscribe(session.id)

      assert {:ok, back} = Games.rejoin_game_session(token)

      assert_receive {:participant_rejoined, %Participant{id: id}}
      assert id == back.id
      assert is_nil(Repo.get(Participant, id).left_at)
    end

    test "o retorno recusado não publica nada", %{session: session} do
      :ok = Games.subscribe(session.id)

      assert {:error, :not_found} = Games.rejoin_game_session("credencial inventada")

      refute_receive {:participant_rejoined, _participant}, 50
    end

    test "a transferência de acesso é publicada", %{session: session} do
      participant = participant_fixture(session)
      :ok = Games.subscribe(session.id)

      assert {:ok, _participant, connection_id} =
               Games.claim_participant_connection(participant)

      assert_receive {:access_transferred, participant_id, ^connection_id}
      assert participant_id == participant.id
    end

    test "a transferência do host é publicada", %{session: session, host: host} do
      scope = user_scope_fixture(host)
      :ok = Games.subscribe(session.id)

      assert {:ok, _session, connection_id} = Games.claim_host_connection(scope, session)

      assert_receive {:host_access_transferred, ^connection_id}
    end

    test "a transferência recusada a um não-host não publica nada", %{session: session} do
      :ok = Games.subscribe(session.id)

      assert {:error, :unauthorized} =
               Games.claim_host_connection(user_scope_fixture(), session)

      refute_receive {:host_access_transferred, _connection_id}, 50
    end
  end

  describe "eventos de ciclo de vida" do
    setup :hosted_waiting_session

    test "o início é publicado", %{scope: scope, session: session} do
      :ok = Games.subscribe(session.id)

      assert {:ok, started} = Games.start_game_session(scope, session, 1)

      assert_receive {:game_started, %GameSession{id: id, status: :in_progress}}
      assert id == started.id
    end

    test "o início recusado não publica nada", %{scope: scope, session: session} do
      :ok = Games.subscribe(session.id)

      assert {:error, :no_connected_participants} =
               Games.start_game_session(scope, session, 0)

      assert {:error, :unauthorized} =
               Games.start_game_session(user_scope_fixture(), session, 1)

      refute_receive {:game_started, _session}, 50
    end

    test "o cancelamento é publicado", %{scope: scope, session: session} do
      :ok = Games.subscribe(session.id)

      assert {:ok, cancelled} = Games.cancel_game_session(scope, session)

      assert_receive {:game_cancelled, %GameSession{id: id, status: :cancelled}}
      assert id == cancelled.id
    end

    test "o cancelamento por quem não hospeda não publica nada", %{session: session} do
      :ok = Games.subscribe(session.id)

      assert {:error, :unauthorized} =
               Games.cancel_game_session(user_scope_fixture(), session)

      refute_receive {:game_cancelled, _session}, 50
    end

    test "a expiração é publicada", %{session: session} do
      :ok = Games.subscribe(session.id)

      assert {:ok, expired} = Games.expire_game_session(session)

      assert_receive {:game_expired, %GameSession{id: id, status: :expired}}
      assert id == expired.id
    end

    test "expirar uma sala já encerrada não publica nada", %{scope: scope, session: session} do
      assert {:ok, cancelled} = Games.cancel_game_session(scope, session)
      :ok = Games.subscribe(session.id)

      assert {:error, :invalid_transition} = Games.expire_game_session(cancelled)

      refute_receive {:game_expired, _session}, 50
    end
  end

  describe "record_host_absence/2" do
    setup :hosted_waiting_session

    test "marca o prazo e publica", %{session: session} do
      :ok = Games.subscribe(session.id)
      at = now()

      assert {:ok, away} = Games.record_host_absence(session.id, at)

      assert away.expires_at == DateTime.add(at, Games.host_absence_timeout(), :second)
      assert_receive {:host_disconnected, expires_at}
      assert expires_at == away.expires_at
    end

    test "a segunda vez é ignorada e não publica", %{session: session} do
      assert {:ok, _away} = Games.record_host_absence(session.id, minutes_ago(1))
      :ok = Games.subscribe(session.id)

      assert Games.record_host_absence(session.id) == :ignored

      refute_receive {:host_disconnected, _expires_at}, 50
    end

    test "a sala encerrada é ignorada", %{scope: scope, session: session} do
      assert {:ok, _cancelled} = Games.cancel_game_session(scope, session)
      :ok = Games.subscribe(session.id)

      assert Games.record_host_absence(session.id) == :ignored

      refute_receive {:host_disconnected, _expires_at}, 50
      assert is_nil(Repo.get!(GameSession, session.id).expires_at)
    end

    test "uma sala que não existe é ignorada" do
      assert Games.record_host_absence(0) == :ignored
    end
  end

  describe "record_host_return/1" do
    setup :hosted_waiting_session

    test "limpa o prazo e publica", %{session: session} do
      assert {:ok, _away} = Games.record_host_absence(session.id, minutes_ago(1))
      :ok = Games.subscribe(session.id)

      assert {:ok, back} = Games.record_host_return(session.id)

      assert is_nil(back.expires_at)
      assert is_nil(back.host_disconnected_at)
      assert_receive {:host_connected, nil}
    end

    test "o host que nunca caiu não publica nada", %{session: session} do
      :ok = Games.subscribe(session.id)

      assert Games.record_host_return(session.id) == :ignored

      refute_receive {:host_connected, _expires_at}, 50
    end

    test "a sala encerrada é ignorada", %{scope: scope, session: session} do
      assert {:ok, _cancelled} = Games.cancel_game_session(scope, session)
      :ok = Games.subscribe(session.id)

      assert Games.record_host_return(session.id) == :ignored

      refute_receive {:host_connected, _expires_at}, 50
    end

    test "uma sala que não existe é ignorada" do
      assert Games.record_host_return(0) == :ignored
    end
  end

  describe "list_participants_with_presence/2" do
    setup :waiting_session

    test "traz todo mundo desconectado quando ninguém está no tópico", %{
      session: session,
      host: host
    } do
      first = participant_fixture(session, %{joined_at: minutes_ago(2)})
      second = participant_fixture(session, %{joined_at: minutes_ago(1)})

      assert {:ok, participants} =
               Games.list_participants_with_presence(session, user_scope_fixture(host))

      assert Enum.map(participants, & &1.id) == [first.id, second.id]
      refute Enum.any?(participants, & &1.connected)
    end

    test "omite quem saiu", %{session: session, host: host} do
      stayed = participant_fixture(session)
      participant_fixture(session, %{left_at: now(), released_at: now()})

      assert {:ok, [listed]} =
               Games.list_participants_with_presence(session, user_scope_fixture(host))

      assert listed.id == stayed.id
    end

    test "recusa quem não é da sala", %{session: session} do
      participant_fixture(session)

      assert Games.list_participants_with_presence(session, user_scope_fixture()) ==
               {:error, :unauthorized}

      assert Games.list_participants_with_presence(session, nil) == {:error, :unauthorized}
    end
  end

  describe "advance_question/3" do
    setup :running_match

    test "o primeiro avanço abre a pergunta 1 com o prazo do servidor", %{
      scope: scope,
      session: session
    } do
      assert {:ok, advanced} = Games.advance_question(scope, session, nil)

      assert advanced.current_question_position == 1
      assert advanced.current_question_started_at
      assert is_nil(advanced.current_question_closed_at)
      assert GameSession.question_open?(advanced)

      assert DateTime.diff(
               advanced.current_question_ends_at,
               advanced.current_question_started_at
             ) == 30
    end

    test "caminha de uma posição para a seguinte até a última", %{
      scope: scope,
      session: session
    } do
      assert {:ok, first} = Games.advance_question(scope, session, nil)
      assert first.current_question_position == 1

      assert {:ok, second} = Games.advance_question(scope, first, 1)
      assert second.current_question_position == 2

      assert {:ok, third} = Games.advance_question(scope, second, 2)
      assert third.current_question_position == 3
      assert GameSession.question_open?(third)
    end

    test "avançar com a pergunta aberta encerra a anterior na mesma transação", %{
      scope: scope,
      session: session
    } do
      assert {:ok, first} = Games.advance_question(scope, session, nil)

      {result, queries} = capture_queries(fn -> Games.advance_question(scope, first, 1) end)

      assert {:ok, second} = result
      assert second.current_question_position == 2
      assert is_nil(second.current_question_closed_at)
      assert Enum.any?(queries, &closes_previous_question?/1)
    end

    test "nada é encerrado quando o avanço parte de uma pergunta já encerrada", %{
      scope: scope,
      session: session
    } do
      assert {:ok, first} = Games.advance_question(scope, session, nil)
      assert {:ok, closed} = Games.close_question(scope, first)

      {result, queries} = capture_queries(fn -> Games.advance_question(scope, closed, 1) end)

      assert {:ok, %GameSession{current_question_position: 2}} = result
      refute Enum.any?(queries, &closes_previous_question?/1)
    end

    test "a partida de uma única pergunta abre e não passa dela" do
      %{scope: scope, session: session} = match_of(1)

      assert {:ok, first} = Games.advance_question(scope, session, nil)
      assert first.current_question_position == 1

      assert {:ok, closed} = Games.close_question(scope, first)
      assert Games.advance_question(scope, closed, 1) == {:error, :no_more_questions}

      current = Repo.get!(GameSession, session.id)
      assert current.status == :in_progress
      assert current.current_question_position == 1
    end

    test "avançar além da última pergunta não muda a partida", %{
      scope: scope,
      session: session
    } do
      assert {:ok, third} = advance_to(scope, session, 3)

      assert Games.advance_question(scope, third, 3) == {:error, :no_more_questions}

      current = Repo.get!(GameSession, session.id)
      assert current.status == :in_progress
      assert current.current_question_position == 3
      assert current.current_question_started_at == third.current_question_started_at
    end

    test "o prazo sai da duração escolhida para a sala" do
      for duration <- GameSession.question_durations() do
        %{scope: scope, session: session} = match_of(1, %{question_duration_seconds: duration})

        assert {:ok, advanced} = Games.advance_question(scope, session, nil)

        assert DateTime.diff(
                 advanced.current_question_ends_at,
                 advanced.current_question_started_at
               ) == duration
      end
    end

    test "uma posição divergente é recusada sem mudar nada", %{scope: scope, session: session} do
      assert {:ok, first} = Games.advance_question(scope, session, nil)

      assert Games.advance_question(scope, first, nil) == {:error, :stale}
      assert Games.advance_question(scope, first, 2) == {:error, :stale}

      current = Repo.get!(GameSession, session.id)
      assert current.current_question_position == 1
      assert current.current_question_started_at == first.current_question_started_at
    end

    test "quem não apresenta a sala não avança", %{session: session} do
      assert Games.advance_question(user_scope_fixture(), session, nil) == {:error, :unauthorized}

      assert is_nil(Repo.get!(GameSession, session.id).current_question_position)
    end

    test "o participante autenticado não avança", %{session: session} do
      player = user_scope_fixture()
      participant_fixture(session, %{user: player.user})

      assert Games.advance_question(player, session, nil) == {:error, :unauthorized}

      assert is_nil(Repo.get!(GameSession, session.id).current_question_position)
    end

    test "só uma partida em andamento avança" do
      for status <- [:waiting, :finished, :cancelled, :expired] do
        %{scope: scope, session: session} = match_of(3, %{status: status})

        assert Games.advance_question(scope, session, nil) == {:error, :invalid_status}
        assert is_nil(Repo.get!(GameSession, session.id).current_question_position)
      end
    end
  end

  describe "close_question/2" do
    setup :running_match

    test "encerra a pergunta aberta", %{scope: scope, session: session} do
      assert {:ok, open} = Games.advance_question(scope, session, nil)

      assert {:ok, closed} = Games.close_question(scope, open)

      assert closed.current_question_position == 1
      assert closed.current_question_closed_at
      refute GameSession.question_open?(closed)
      assert GameSession.question_closed?(closed)
    end

    test "encerrar de novo não mexe no instante registrado", %{scope: scope, session: session} do
      assert {:ok, open} = Games.advance_question(scope, session, nil)
      assert {:ok, closed} = Games.close_question(scope, open)

      assert {:ok, again} = Games.close_question(scope, closed)

      assert again.current_question_closed_at == closed.current_question_closed_at
    end

    test "sem nenhuma pergunta corrente não há o que encerrar", %{
      scope: scope,
      session: session
    } do
      assert Games.close_question(scope, session) == {:error, :no_open_question}

      assert is_nil(Repo.get!(GameSession, session.id).current_question_closed_at)
    end

    test "encerrar a última pergunta não finaliza a partida", %{scope: scope, session: session} do
      assert {:ok, last} = advance_to(scope, session, 3)

      assert {:ok, closed} = Games.close_question(scope, last)

      assert closed.status == :in_progress
      assert Repo.get!(GameSession, session.id).status == :in_progress
    end

    test "quem não apresenta a sala não encerra", %{scope: scope, session: session} do
      assert {:ok, open} = Games.advance_question(scope, session, nil)

      assert Games.close_question(user_scope_fixture(), open) == {:error, :unauthorized}

      assert is_nil(Repo.get!(GameSession, session.id).current_question_closed_at)
    end

    test "só uma partida em andamento encerra" do
      for status <- [:waiting, :finished, :cancelled, :expired] do
        %{scope: scope, session: session} =
          match_of(3, %{status: status, current_question_position: 1})

        assert Games.close_question(scope, session) == {:error, :invalid_status}
        assert is_nil(Repo.get!(GameSession, session.id).current_question_closed_at)
      end
    end
  end

  describe "close_question_by_timeout/1" do
    setup :running_match

    test "encerra a pergunta cujo prazo venceu e publica o evento", %{
      scope: scope,
      session: session
    } do
      assert {:ok, open} = Games.advance_question(scope, session, nil)
      ending_in(open, -1_000)
      :ok = Games.subscribe(session.id)

      assert {:ok, closed} = Games.close_question_by_timeout(session.id)

      assert closed.current_question_position == 1
      refute is_nil(closed.current_question_closed_at)
      assert Repo.get!(GameSession, session.id).current_question_closed_at

      assert_receive {:question_closed, %GameSession{current_question_position: 1}}
      refute_receive {:question_closed, _repeated}, 50
    end

    test "não pede scope nenhum: quem chama é o sistema", %{scope: scope, session: session} do
      assert {:ok, open} = Games.advance_question(scope, session, nil)
      ending_in(open, -1_000)

      assert {:ok, %GameSession{}} = Games.close_question_by_timeout(session.id)
    end

    test "a pergunta ainda no prazo devolve :not_due e continua aberta", %{
      scope: scope,
      session: session
    } do
      assert {:ok, open} = Games.advance_question(scope, session, nil)
      ending_in(open, 5_000)
      :ok = Games.subscribe(session.id)

      assert Games.close_question_by_timeout(session.id) == {:error, :not_due}

      assert is_nil(Repo.get!(GameSession, session.id).current_question_closed_at)
      refute_receive {:question_closed, _nothing}, 50
    end

    test "a pergunta já encerrada volta com o mesmo instante e sem evento novo", %{
      scope: scope,
      session: session
    } do
      assert {:ok, open} = Games.advance_question(scope, session, nil)
      assert {:ok, closed} = Games.close_question(scope, open)

      ending_in(closed, -1_000)
      |> Ecto.Changeset.change(%{
        current_question_closed_at: closed.current_question_closed_at
      })
      |> Repo.update!()

      :ok = Games.subscribe(session.id)

      assert {:ok, again} = Games.close_question_by_timeout(session.id)

      assert again.current_question_closed_at == closed.current_question_closed_at
      refute_receive {:question_closed, _repeated}, 50
    end

    test "a partida que não avançou para pergunta nenhuma devolve :no_open_question", %{
      session: session
    } do
      assert Games.close_question_by_timeout(session.id) == {:error, :no_open_question}
    end

    test "a sala ainda no lobby devolve :invalid_status" do
      session = game_session_fixture(%{status: :waiting})

      assert Games.close_question_by_timeout(session.id) == {:error, :invalid_status}
    end

    test "a partida já encerrada devolve :invalid_status", %{scope: scope, session: session} do
      assert {:ok, open} = Games.advance_question(scope, session, nil)
      ending_in(open, -1_000)
      assert {:ok, _cancelled} = Games.cancel_game_session(scope, session)

      assert Games.close_question_by_timeout(session.id) == {:error, :invalid_status}
    end

    test "a partida inexistente devolve :not_found" do
      assert Games.close_question_by_timeout(-1) == {:error, :not_found}
    end

    test "o encerramento por tempo é indistinguível do encerramento pelo host", %{
      scope: scope,
      session: session
    } do
      assert {:ok, open} = Games.advance_question(scope, session, nil)
      ending_in(open, -1_000)
      assert {:ok, by_time} = Games.close_question_by_timeout(session.id)

      %{scope: other_scope, session: other} = match_of(3)
      assert {:ok, other_open} = Games.advance_question(other_scope, other, nil)
      assert {:ok, by_host} = Games.close_question(other_scope, other_open)

      assert by_time.status == by_host.status
      assert by_time.current_question_position == by_host.current_question_position
      refute is_nil(by_time.current_question_closed_at)
      refute is_nil(by_host.current_question_closed_at)
    end
  end

  describe "finish_game_session/2" do
    setup :running_match

    test "finaliza a partida da última pergunta encerrada e libera todo mundo", %{
      scope: scope,
      session: session,
      participant: participant
    } do
      assert {:ok, last} = advance_to(scope, session, 3)
      assert {:ok, closed} = Games.close_question(scope, last)

      assert {:ok, finished} = Games.finish_game_session(scope, closed)

      assert finished.status == :finished
      assert finished.finished_at
      assert is_nil(finished.expires_at)
      assert Repo.get!(Participant, participant.id).released_at
    end

    test "finalizar no meio mantém a posição corrente", %{scope: scope, session: session} do
      assert {:ok, second} = advance_to(scope, session, 2)

      assert {:ok, finished} = Games.finish_game_session(scope, second)

      assert finished.status == :finished
      assert finished.current_question_position == 2
      assert finished.current_question_started_at == second.current_question_started_at
    end

    test "finaliza uma partida que nunca avançou", %{scope: scope, session: session} do
      assert {:ok, finished} = Games.finish_game_session(scope, session)

      assert finished.status == :finished
      assert is_nil(finished.current_question_position)
    end

    test "finalizar de novo devolve a mesma partida", %{scope: scope, session: session} do
      assert {:ok, finished} = Games.finish_game_session(scope, session)

      assert {:ok, again} = Games.finish_game_session(scope, finished)

      assert again.status == :finished
      assert again.finished_at == finished.finished_at
    end

    test "libera inclusive quem já tinha saído da sala", %{scope: scope, session: session} do
      gone = participant_fixture(session, %{left_at: now(), released_at: now()})
      staying = participant_fixture(session)

      assert {:ok, _finished} = Games.finish_game_session(scope, session)

      assert Repo.get!(Participant, gone.id).released_at == gone.released_at
      assert Repo.get!(Participant, staying.id).released_at
    end

    test "quem não apresenta a sala não finaliza", %{session: session} do
      assert Games.finish_game_session(user_scope_fixture(), session) == {:error, :unauthorized}

      assert Repo.get!(GameSession, session.id).status == :in_progress
    end

    test "o participante autenticado não finaliza", %{session: session} do
      player = user_scope_fixture()
      participant_fixture(session, %{user: player.user})

      assert Games.finish_game_session(player, session) == {:error, :unauthorized}

      assert Repo.get!(GameSession, session.id).status == :in_progress
    end

    test "só uma partida em andamento finaliza" do
      for status <- [:waiting, :cancelled, :expired] do
        %{scope: scope, session: session} = match_of(3, %{status: status})

        assert Games.finish_game_session(scope, session) == {:error, :invalid_status}
        assert Repo.get!(GameSession, session.id).status == status
      end
    end

    test "cancelar continua encerrando uma partida com pergunta aberta", %{
      scope: scope,
      session: session,
      participant: participant
    } do
      assert {:ok, open} = Games.advance_question(scope, session, nil)

      assert {:ok, cancelled} = Games.cancel_game_session(scope, open)

      assert cancelled.status == :cancelled
      assert cancelled.current_question_position == 1
      assert Repo.get!(Participant, participant.id).released_at
    end
  end

  describe "game_state/2" do
    setup :running_match

    test "antes do primeiro avanço a partida está pendente", %{
      scope: scope,
      session: session,
      participant: participant
    } do
      assert {:ok, state} = Games.game_state(session, scope)

      assert state.status == :in_progress
      assert is_nil(state.question_number)
      assert state.question_count == 3
      assert state.question_state == :pending
      assert is_nil(state.question_text)
      assert is_nil(state.ends_at)
      assert is_nil(state.seconds_left)
      refute state.last_question?
      assert state.options == []

      assert {:ok, playing} = Games.game_state(session, participant)

      assert playing.question_state == :pending
      assert playing.options == []
      assert is_nil(playing.my_answer_option_id)
    end

    test "a visão do host traz o gabarito com a pergunta aberta", %{
      scope: scope,
      session: session
    } do
      assert {:ok, open} = Games.advance_question(scope, session, nil)

      assert {:ok, state} = Games.game_state(open, scope)

      assert state.question_number == 1
      assert state.question_state == :open
      assert state.question_text == "Pergunta 1 da partida"
      assert state.ends_at == open.current_question_ends_at
      assert state.seconds_left > 0 and state.seconds_left <= 30
      assert Enum.map(state.options, & &1.correct) == [true, false, false, false]
      assert Enum.map(state.options, & &1.position) == [1, 2, 3, 4]
      assert Enum.map(state.options, & &1.text) |> hd() == "Brasília"
      refute Map.has_key?(state, :my_answer_option_id)
    end

    test "a visão de quem joga não vaza o gabarito com a pergunta aberta", %{
      scope: scope,
      session: session,
      participant: participant
    } do
      assert {:ok, open} = Games.advance_question(scope, session, nil)

      assert {:ok, state} = Games.game_state(open, participant)

      assert state.question_state == :open
      assert Enum.all?(state.options, &is_nil(&1.correct))
      assert is_nil(state.my_answer_option_id)
    end

    test "a alternativa correta aparece para quem joga depois do encerramento", %{
      scope: scope,
      session: session,
      participant: participant
    } do
      assert {:ok, open} = Games.advance_question(scope, session, nil)
      assert {:ok, closed} = Games.close_question(scope, open)

      assert {:ok, state} = Games.game_state(closed, participant)

      assert state.question_state == :closed
      assert Enum.map(state.options, & &1.correct) == [true, false, false, false]
      assert state.seconds_left == 0
    end

    test "o host vê o gabarito também com a pergunta encerrada", %{
      scope: scope,
      session: session
    } do
      assert {:ok, open} = Games.advance_question(scope, session, nil)
      assert {:ok, closed} = Games.close_question(scope, open)

      assert {:ok, state} = Games.game_state(closed, scope)

      assert state.question_state == :closed
      assert Enum.map(state.options, & &1.correct) == [true, false, false, false]
    end

    test "traz a alternativa que a pessoa escolheu", %{
      scope: scope,
      session: session,
      participant: participant,
      questions: questions
    } do
      assert {:ok, open} = Games.advance_question(scope, session, nil)
      option = option_at(questions, 1, 2)
      answer_fixture(participant, option)

      assert {:ok, state} = Games.game_state(open, participant)

      assert state.my_answer_option_id == option.id
    end

    test "o participante autenticado lê pelo próprio escopo sem ver o gabarito", %{
      scope: scope,
      session: session,
      questions: questions
    } do
      player = user_scope_fixture()
      playing = participant_fixture(session, %{user: player.user})
      assert {:ok, open} = Games.advance_question(scope, session, nil)
      option = option_at(questions, 1, 3)
      answer_fixture(playing, option)

      assert {:ok, state} = Games.game_state(open, player)

      assert Enum.all?(state.options, &is_nil(&1.correct))
      assert state.my_answer_option_id == option.id
    end

    test "o tempo restante nunca fica negativo", %{scope: scope, session: session} do
      overdue = on_question(session, 1, started_at: minutes_ago_usec(2))

      assert {:ok, state} = Games.game_state(overdue, scope)

      assert state.question_state == :open
      assert state.seconds_left == 0
    end

    test "last_question? só vale na última posição", %{scope: scope, session: session} do
      assert {:ok, first} = Games.advance_question(scope, session, nil)
      assert {:ok, first_state} = Games.game_state(first, scope)
      refute first_state.last_question?

      assert {:ok, last} = advance_to(scope, first, 3)
      assert {:ok, last_state} = Games.game_state(last, scope)
      assert last_state.last_question?
    end

    test "quem jogou continua lendo o estado depois do fim", %{
      scope: scope,
      session: session,
      participant: participant
    } do
      assert {:ok, second} = advance_to(scope, session, 2)
      assert {:ok, finished} = Games.finish_game_session(scope, second)

      assert {:ok, state} = Games.game_state(finished, participant)

      assert state.status == :finished
      assert state.question_number == 2
      assert state.question_state == :closed
    end

    test "uma posição sem pergunta congelada não quebra a leitura" do
      scope = user_scope_fixture()

      session =
        game_session_fixture(%{
          host: scope.user,
          status: :in_progress,
          current_question_position: 1
        })

      participant = participant_fixture(session)

      assert {:ok, state} = Games.game_state(session, participant)

      assert state.question_state == :open
      assert state.question_count == 0
      assert is_nil(state.question_text)
      assert is_nil(state.ends_at)
      assert is_nil(state.seconds_left)
      assert state.options == []
      assert is_nil(state.my_answer_option_id)
    end

    test "quem não é da sala não lê o estado", %{session: session} do
      outsider = participant_fixture(game_session_fixture(%{status: :in_progress}))

      assert Games.game_state(session, user_scope_fixture()) == {:error, :unauthorized}
      assert Games.game_state(session, outsider) == {:error, :unauthorized}
      assert Games.game_state(session, nil) == {:error, :unauthorized}
    end
  end

  describe "eventos da partida" do
    setup :running_match

    test "cada comando publica o próprio evento uma única vez", %{
      scope: scope,
      session: session
    } do
      :ok = Games.subscribe(session.id)

      assert {:ok, open} = Games.advance_question(scope, session, nil)
      assert_receive {:question_advanced, %GameSession{current_question_position: 1}}
      refute_receive {:question_advanced, _repeated}, 50

      assert {:ok, closed} = Games.close_question(scope, open)
      assert_receive {:question_closed, %GameSession{}}
      assert {:ok, _again} = Games.close_question(scope, closed)
      refute_receive {:question_closed, _repeated}, 50

      assert {:ok, finished} = Games.finish_game_session(scope, closed)
      assert_receive {:game_finished, %GameSession{status: :finished}}
      assert {:ok, _idempotent} = Games.finish_game_session(scope, finished)
      refute_receive {:game_finished, _repeated}, 50
    end

    test "o evento chega com a partida já gravada", %{scope: scope, session: session} do
      :ok = Games.subscribe(session.id)

      assert {:ok, _open} = Games.advance_question(scope, session, nil)

      assert_receive {:question_advanced, %GameSession{} = published}
      current = Repo.get!(GameSession, session.id)
      assert current.current_question_position == published.current_question_position
      assert current.current_question_started_at == published.current_question_started_at
    end

    test "um comando recusado não publica nada", %{scope: scope, session: session} do
      :ok = Games.subscribe(session.id)

      assert Games.advance_question(user_scope_fixture(), session, nil) == {:error, :unauthorized}
      assert Games.close_question(scope, session) == {:error, :no_open_question}
      assert Games.finish_game_session(user_scope_fixture(), session) == {:error, :unauthorized}

      assert {:ok, open} = Games.advance_question(scope, session, nil)
      assert_receive {:question_advanced, %GameSession{}}

      assert Games.advance_question(scope, open, nil) == {:error, :stale}

      refute_receive {:question_advanced, _repeated}, 50
      refute_receive {:question_closed, _none}, 50
      refute_receive {:game_finished, _none}, 50
    end
  end

  describe "comandos da partida sob concorrência" do
    test "dois avanços com a mesma posição andam uma pergunta só" do
      %{scope: scope, session: session} = match_of(3)
      assert {:ok, open} = Games.advance_question(scope, session, nil)
      :ok = Games.subscribe(session.id)

      results = in_parallel([1, 2], fn _attempt -> Games.advance_question(scope, open, 1) end)

      assert Enum.count(results, &match?({:ok, %GameSession{current_question_position: 2}}, &1)) ==
               1

      assert Enum.count(results, &(&1 == {:error, :stale})) == 1
      assert Repo.get!(GameSession, session.id).current_question_position == 2

      assert_receive {:question_advanced, %GameSession{current_question_position: 2}}
      refute_receive {:question_advanced, _repeated}, 50
    end

    test "avanço e encerramento simultâneos não deixam a partida inconsistente" do
      %{scope: scope, session: session} = match_of(3)
      assert {:ok, open} = Games.advance_question(scope, session, nil)

      in_parallel([:advance, :close], fn
        :advance -> Games.advance_question(scope, open, 1)
        :close -> Games.close_question(scope, open)
      end)

      current = Repo.get!(GameSession, session.id)
      assert current.status == :in_progress
      assert current.current_question_position in [1, 2]

      assert DateTime.diff(
               current.current_question_ends_at,
               current.current_question_started_at
             ) == current.question_duration_seconds

      assert is_nil(current.current_question_closed_at) or
               DateTime.compare(
                 current.current_question_closed_at,
                 current.current_question_started_at
               ) != :lt
    end

    test "duas finalizações simultâneas encerram a partida uma vez só" do
      %{scope: scope, session: session} = match_of(3)
      participant = participant_fixture(session)
      :ok = Games.subscribe(session.id)

      results = in_parallel([1, 2], fn _attempt -> Games.finish_game_session(scope, session) end)

      assert Enum.all?(results, &match?({:ok, %GameSession{status: :finished}}, &1))
      assert Repo.get!(GameSession, session.id).status == :finished
      assert Repo.get!(Participant, participant.id).released_at

      assert_receive {:game_finished, %GameSession{}}
      refute_receive {:game_finished, _repeated}, 50
    end

    test "dois encerramentos simultâneos registram um único instante" do
      %{scope: scope, session: session} = match_of(3)
      assert {:ok, open} = Games.advance_question(scope, session, nil)
      :ok = Games.subscribe(session.id)

      results = in_parallel([1, 2], fn _attempt -> Games.close_question(scope, open) end)

      assert [{:ok, %GameSession{} = first}, {:ok, %GameSession{} = second}] = results
      assert first.current_question_closed_at == second.current_question_closed_at

      assert_receive {:question_closed, %GameSession{}}
      refute_receive {:question_closed, _repeated}, 50
    end
  end

  describe "answer_question/3" do
    setup :open_match

    test "grava a resposta do participante com o instante do servidor", %{
      session: session,
      questions: questions,
      participant: participant
    } do
      option = option_at(questions, 1, 2)
      before = now_usec()

      assert {:ok, %{answer: answer, session: current, closed?: false}} =
               Games.answer_question(participant, option.id, 3)

      assert answer.participant_id == participant.id
      assert answer.game_session_id == session.id
      assert answer.game_session_question_id == option.game_session_question_id
      assert answer.game_session_answer_option_id == option.id
      assert DateTime.compare(answer.answered_at, before) != :lt
      assert DateTime.compare(answer.answered_at, now_usec()) != :gt
      assert GameSession.question_open?(current)

      assert [%Answer{id: id}] = answers_of(participant)
      assert id == answer.id
    end

    test "aceita a alternativa de qualquer uma das quatro posições", %{
      session: session,
      questions: questions
    } do
      for position <- 1..4 do
        option = option_at(questions, 1, position)
        participant = participant_fixture(session)
        option_id = option.id

        assert {:ok, %{answer: %Answer{game_session_answer_option_id: ^option_id}}} =
                 Games.answer_question(participant, option_id, 25)
      end
    end

    test "trocar de alternativa uma, duas e três vezes deixa sempre uma única linha", %{
      questions: questions,
      participant: participant
    } do
      for position <- [2, 4, 1, 3] do
        option_id = option_at(questions, 1, position).id

        assert {:ok, %{answer: %Answer{game_session_answer_option_id: ^option_id}}} =
                 Games.answer_question(participant, option_id, 25)

        assert [%Answer{game_session_answer_option_id: ^option_id}] = answers_of(participant)
      end
    end

    test "a troca reescreve answered_at e preserva o instante da primeira resposta", %{
      questions: questions,
      participant: participant
    } do
      first = option_at(questions, 1, 1)
      second = option_at(questions, 1, 3)

      assert {:ok, %{answer: original}} = Games.answer_question(participant, first.id, 25)
      assert {:ok, %{answer: replaced}} = Games.answer_question(participant, second.id, 25)

      assert replaced.id == original.id
      assert replaced.inserted_at == original.inserted_at
      assert DateTime.compare(replaced.answered_at, original.answered_at) == :gt
      assert [%Answer{}] = answers_of(participant)
    end

    test "responder de novo a mesma alternativa apenas atualiza answered_at", %{
      questions: questions,
      participant: participant
    } do
      option = option_at(questions, 1, 4)

      assert {:ok, %{answer: first}} = Games.answer_question(participant, option.id, 25)
      assert {:ok, %{answer: again}} = Games.answer_question(participant, option.id, 25)

      assert again.id == first.id
      assert again.game_session_answer_option_id == option.id
      assert DateTime.compare(again.answered_at, first.answered_at) == :gt
      assert [%Answer{}] = answers_of(participant)
    end

    test "a resposta que chega com milissegundos de sobra é aceita", %{
      session: session,
      questions: questions,
      participant: participant
    } do
      _still_open = ending_in(session, 300)

      assert {:ok, %{answer: %Answer{}}} =
               Games.answer_question(participant, option_at(questions, 1, 1).id, 25)
    end

    test "a resposta que chega um milissegundo depois do prazo é recusada", %{
      session: session,
      questions: questions,
      participant: participant
    } do
      _late = ending_in(session, -1)

      assert Games.answer_question(participant, option_at(questions, 1, 1).id, 25) ==
               {:error, :time_is_up}

      assert answers_of(participant) == []
    end

    test "a pergunta encerrada não recebe mais respostas", %{
      scope: scope,
      session: session,
      questions: questions,
      participant: participant
    } do
      assert {:ok, _closed} = Games.close_question(scope, session)

      assert Games.answer_question(participant, option_at(questions, 1, 1).id, 25) ==
               {:error, :question_closed}

      assert answers_of(participant) == []
    end

    test "antes do primeiro avanço não há pergunta para responder" do
      %{session: session, questions: questions} = match_of(3)
      participant = participant_fixture(session)

      assert Games.answer_question(participant, option_at(questions, 1, 1).id, 25) ==
               {:error, :no_open_question}

      assert answers_of(participant) == []
    end

    test "só uma partida em andamento recebe respostas" do
      for status <- [:waiting, :finished, :cancelled, :expired] do
        %{session: session, questions: questions} = match_of(1, %{status: status})
        open = on_question(session, 1, started_at: now_usec())
        participant = participant_fixture(open)

        assert Games.answer_question(participant, option_at(questions, 1, 1).id, 25) ==
                 {:error, :invalid_status}

        assert answers_of(participant) == []
      end
    end

    test "a alternativa de outra pergunta da mesma partida é recusada", %{
      questions: questions,
      participant: participant
    } do
      assert Games.answer_question(participant, option_at(questions, 2, 1).id, 25) ==
               {:error, :option_not_found}

      assert answers_of(participant) == []
    end

    test "a alternativa de outra partida é recusada", %{participant: participant} do
      %{questions: elsewhere} = match_of(1)

      assert Games.answer_question(participant, option_at(elsewhere, 1, 1).id, 25) ==
               {:error, :option_not_found}

      assert answers_of(participant) == []
    end

    test "um id de alternativa que não existe é recusado", %{participant: participant} do
      assert Games.answer_question(participant, 0, 25) == {:error, :option_not_found}
      assert answers_of(participant) == []
    end

    test "quem saiu da sala não responde, nem com a participação que tinha em mãos", %{
      questions: questions,
      participant: participant
    } do
      option = option_at(questions, 1, 1)
      assert {:ok, gone} = Games.leave_game_session(participant)

      assert Games.answer_question(gone, option.id, 25) == {:error, :left_session}
      assert Games.answer_question(participant, option.id, 25) == {:error, :left_session}
      assert answers_of(participant) == []
    end

    test "o participante de outra partida não responde nesta", %{questions: questions} do
      %{scope: scope, session: session} = match_of(1)
      assert {:ok, open} = Games.advance_question(scope, session, nil)
      stranger = participant_fixture(open)

      assert Games.answer_question(stranger, option_at(questions, 1, 1).id, 25) ==
               {:error, :option_not_found}

      assert answers_of(stranger) == []
    end

    test "as respostas das perguntas anteriores continuam existindo quando a partida avança", %{
      scope: scope,
      session: session,
      questions: questions,
      participant: participant
    } do
      assert {:ok, _first} = Games.answer_question(participant, option_at(questions, 1, 1).id, 25)
      assert {:ok, second} = Games.advance_question(scope, session, 1)
      assert {:ok, _also} = Games.answer_question(participant, option_at(questions, 2, 2).id, 25)
      assert {:ok, _third} = Games.advance_question(scope, second, 2)

      assert [first, second] = answers_of(participant)
      assert first.game_session_question_id == option_at(questions, 1, 1).game_session_question_id

      assert second.game_session_question_id ==
               option_at(questions, 2, 2).game_session_question_id
    end
  end

  describe "answer_question/3 e o encerramento automático" do
    test "a pergunta encerra quando o único conectado responde" do
      %{session: session, questions: questions, participants: [only]} = open_match_with(1)
      :ok = Games.subscribe(session.id)

      assert {:ok, %{closed?: true, session: closed}} =
               Games.answer_question(only, option_at(questions, 1, 1).id, 1)

      assert closed.current_question_closed_at
      refute GameSession.question_open?(Repo.get!(GameSession, session.id))

      assert_receive {:question_closed, %GameSession{}}
      refute_receive {:question_closed, _repeated}, 50
    end

    test "com três conectados só a terceira resposta encerra a pergunta" do
      %{session: session, questions: questions, participants: [a, b, c]} = open_match_with(3)
      option = option_at(questions, 1, 1)

      assert {:ok, %{closed?: false}} = Games.answer_question(a, option.id, 3)
      assert {:ok, %{closed?: false}} = Games.answer_question(b, option.id, 3)
      assert GameSession.question_open?(Repo.get!(GameSession, session.id))

      assert {:ok, %{closed?: true}} = Games.answer_question(c, option.id, 3)
      refute GameSession.question_open?(Repo.get!(GameSession, session.id))
    end

    test "faltando alguém, a pergunta continua aberta" do
      %{session: session, questions: questions, participants: [a, b, _c]} = open_match_with(3)
      option = option_at(questions, 1, 1)

      assert {:ok, %{closed?: false}} = Games.answer_question(a, option.id, 3)
      assert {:ok, %{closed?: false}} = Games.answer_question(b, option.id, 3)

      assert GameSession.question_open?(Repo.get!(GameSession, session.id))
    end

    test "quem está desconectado não segura a pergunta" do
      %{session: session, questions: questions, participants: [a, b, _away]} = open_match_with(3)
      option = option_at(questions, 1, 1)

      assert {:ok, %{closed?: false}} = Games.answer_question(a, option.id, 2)
      assert {:ok, %{closed?: true}} = Games.answer_question(b, option.id, 2)

      refute GameSession.question_open?(Repo.get!(GameSession, session.id))
    end

    test "com ninguém conectado o encerramento automático não dispara" do
      %{session: session, questions: questions, participants: [a, b]} = open_match_with(2)
      option = option_at(questions, 1, 1)

      assert {:ok, %{closed?: false}} = Games.answer_question(a, option.id, 0)
      assert {:ok, %{closed?: false}} = Games.answer_question(b, option.id, 0)

      assert GameSession.question_open?(Repo.get!(GameSession, session.id))
    end

    test "quem chega depois do encerramento automático recebe :question_closed" do
      %{session: session, questions: questions, participants: [a, late]} = open_match_with(2)
      option = option_at(questions, 1, 1)

      assert {:ok, %{closed?: true}} = Games.answer_question(a, option.id, 1)
      assert Games.answer_question(late, option.id, 1) == {:error, :question_closed}

      assert answers_of(late) == []
      assert Games.current_answers_count(Repo.get!(GameSession, session.id)) == 1
    end
  end

  describe "answer_question/3 sob concorrência" do
    test "vinte e cinco respostas simultâneas geram vinte e cinco linhas e um só encerramento" do
      %{session: session, questions: questions, participants: participants} = open_match_with(25)
      option = option_at(questions, 1, 1)
      :ok = Games.subscribe(session.id)

      results = in_parallel(participants, &Games.answer_question(&1, option.id, 25))

      assert Enum.count(results, &match?({:ok, %{closed?: true}}, &1)) == 1
      assert Enum.count(results, &match?({:ok, %{closed?: false}}, &1)) == 24

      current = Repo.get!(GameSession, session.id)
      assert Games.current_answers_count(current) == 25
      assert current.current_question_closed_at

      assert_receive {:question_closed, %GameSession{}}
      refute_receive {:question_closed, _repeated}, 50
    end

    test "dois cliques simultâneos do mesmo participante geram uma única resposta" do
      %{questions: questions, participants: [participant]} = open_match_with(1)
      options = [option_at(questions, 1, 1), option_at(questions, 1, 3)]

      results = in_parallel(options, &Games.answer_question(participant, &1.id, 25))

      assert Enum.all?(results, &match?({:ok, %{answer: %Answer{}}}, &1))
      assert [%Answer{game_session_answer_option_id: chosen}] = answers_of(participant)
      assert chosen in Enum.map(options, & &1.id)
    end

    test "resposta e encerramento do host ao mesmo tempo nunca gravam depois do closed_at" do
      %{scope: scope, session: session, questions: questions, participants: [participant]} =
        open_match_with(1)

      option = option_at(questions, 1, 1)

      results =
        in_parallel([:answer, :close], fn
          :answer -> Games.answer_question(participant, option.id, 25)
          :close -> Games.close_question(scope, session)
        end)

      assert Enum.any?(results, &match?({:ok, %GameSession{}}, &1))
      closed = Repo.get!(GameSession, session.id)
      assert closed.current_question_closed_at

      case answers_of(participant) do
        [] ->
          assert {:error, :question_closed} in results

        [answer] ->
          assert DateTime.compare(answer.answered_at, closed.current_question_closed_at) != :gt
      end
    end
  end

  describe "leitura das respostas da pergunta corrente" do
    setup :open_match

    test "get_current_answer/2 devolve a escolha que ficou", %{
      session: session,
      questions: questions,
      participant: participant
    } do
      assert is_nil(Games.get_current_answer(session, participant))

      first = option_at(questions, 1, 1)
      second = option_at(questions, 1, 4)

      assert {:ok, _recorded} = Games.answer_question(participant, first.id, 25)

      assert %Answer{game_session_answer_option_id: chosen} =
               Games.get_current_answer(session, participant)

      assert chosen == first.id

      assert {:ok, _swapped} = Games.answer_question(participant, second.id, 25)

      assert %Answer{game_session_answer_option_id: swapped} =
               Games.get_current_answer(session, participant)

      assert swapped == second.id
    end

    test "get_current_answer/2 é nil antes do primeiro avanço" do
      %{session: session} = match_of(3)
      participant = participant_fixture(session)

      assert is_nil(Games.get_current_answer(session, participant))
    end

    test "get_current_answer/2 ignora a resposta da pergunta anterior", %{
      scope: scope,
      session: session,
      questions: questions,
      participant: participant
    } do
      assert {:ok, _first} = Games.answer_question(participant, option_at(questions, 1, 1).id, 25)
      assert {:ok, second} = Games.advance_question(scope, session, 1)

      assert is_nil(Games.get_current_answer(second, participant))
    end

    test "current_answers_count/1 conta zero, um e vinte e cinco" do
      %{session: session} = match_of(3)
      assert Games.current_answers_count(session) == 0

      %{session: open, questions: questions, participants: participants} = open_match_with(25)
      assert Games.current_answers_count(open) == 0

      option = option_at(questions, 1, 1)
      [first | rest] = participants

      assert {:ok, _one} = Games.answer_question(first, option.id, 0)
      assert Games.current_answers_count(open) == 1

      for participant <- rest do
        assert {:ok, _more} = Games.answer_question(participant, option.id, 0)
      end

      assert Games.current_answers_count(open) == 25
    end

    test "answered_participant_ids/1 ignora as respostas das perguntas anteriores" do
      %{scope: scope, session: session, questions: questions, participants: [a, b]} =
        open_match_with(2)

      assert Games.answered_participant_ids(session) == MapSet.new()

      assert {:ok, _first} = Games.answer_question(a, option_at(questions, 1, 1).id, 0)
      assert Games.answered_participant_ids(session) == MapSet.new([a.id])

      assert {:ok, second} = Games.advance_question(scope, session, 1)
      assert Games.answered_participant_ids(second) == MapSet.new()

      assert {:ok, _also} = Games.answer_question(b, option_at(questions, 2, 3).id, 0)
      assert Games.answered_participant_ids(second) == MapSet.new([b.id])
    end

    test "answered_participant_ids/1 é vazio antes do primeiro avanço" do
      %{session: session} = match_of(3)

      assert Games.answered_participant_ids(session) == MapSet.new()
    end
  end

  describe "eventos da resposta" do
    test "cada resposta publica answer_submitted com a contagem da pergunta" do
      %{session: session, questions: questions, participants: [a, b]} = open_match_with(2)
      session_id = session.id
      option = option_at(questions, 1, 1)
      :ok = Games.subscribe(session_id)

      assert {:ok, _first} = Games.answer_question(a, option.id, 0)
      assert_receive {:answer_submitted, ^session_id, 1}

      assert {:ok, _second} = Games.answer_question(b, option.id, 0)
      assert_receive {:answer_submitted, ^session_id, 2}
    end

    test "a troca publica o evento de novo, sem mudar a contagem" do
      %{session: session, questions: questions, participants: [participant]} = open_match_with(1)
      session_id = session.id
      :ok = Games.subscribe(session_id)

      assert {:ok, _first} = Games.answer_question(participant, option_at(questions, 1, 1).id, 0)
      assert_receive {:answer_submitted, ^session_id, 1}

      assert {:ok, _swap} = Games.answer_question(participant, option_at(questions, 1, 2).id, 0)
      assert_receive {:answer_submitted, ^session_id, 1}
    end

    test "uma resposta recusada não publica nada" do
      %{scope: scope, session: session, questions: questions, participants: [participant]} =
        open_match_with(1)

      :ok = Games.subscribe(session.id)

      assert Games.answer_question(participant, option_at(questions, 2, 1).id, 0) ==
               {:error, :option_not_found}

      assert {:ok, closed} = Games.close_question(scope, session)
      assert_receive {:question_closed, %GameSession{}}

      assert Games.answer_question(participant, option_at(questions, 1, 1).id, 0) ==
               {:error, :question_closed}

      refute_receive {:answer_submitted, _id, _count}, 50
      refute_receive {:question_closed, _repeated}, 50
      assert is_nil(Games.get_current_answer(closed, participant))
    end
  end

  # A match sitting on its first question, open, with `count` people signed up —
  # the state every answer starts from.
  defp open_match_with(count) do
    %{scope: scope, session: session, questions: questions} = match_of(3)
    {:ok, open} = Games.advance_question(scope, session, nil)

    %{
      scope: scope,
      session: open,
      questions: questions,
      participants: Enum.map(1..count//1, fn _seat -> participant_fixture(open) end)
    }
  end

  defp open_match(_context) do
    context = open_match_with(1)
    Map.put(context, :participant, hd(context.participants))
  end

  # The deadline is written by the context out of the duration of the room, so a
  # test that needs one about to run out — or just gone — places the start far
  # enough back for `ends_at` to land exactly where it wants it.
  defp ending_in(session, milliseconds) do
    started_at =
      now_usec()
      |> DateTime.add(milliseconds, :millisecond)
      |> DateTime.add(-session.question_duration_seconds, :second)

    on_question(session, session.current_question_position, started_at: started_at)
  end

  defp answers_of(%Participant{id: id}) do
    Answer |> where([a], a.participant_id == ^id) |> order_by([a], asc: a.id) |> Repo.all()
  end

  defp start_session(session) do
    session |> GameSession.status_changeset(:in_progress) |> Repo.update!()
  end

  # A running match of three frozen questions with somebody playing it — the
  # shape every command of the execution starts from.
  defp running_match(_context) do
    %{scope: scope, session: session, questions: questions} = match_of(3)

    %{
      scope: scope,
      session: session,
      questions: questions,
      participant: participant_fixture(session)
    }
  end

  defp match_of(count, attrs \\ %{}) do
    scope = user_scope_fixture()

    session =
      attrs
      |> Map.merge(%{host: scope.user})
      |> Map.put_new(:status, :in_progress)
      |> game_session_fixture()

    %{scope: scope, session: session, questions: snapshot_fixture(session, count: count)}
  end

  defp advance_to(scope, session, position) do
    Enum.reduce((session.current_question_position || 0)..(position - 1)//1, {:ok, session}, fn
      expected, {:ok, current} ->
        Games.advance_question(scope, current, if(expected == 0, do: nil, else: expected))
    end)
  end

  # The match columns have no changeset on purpose — moving from one question to
  # the next is the context's job — so a test that needs a match already sitting
  # on a given deadline writes them.
  defp on_question(session, position, opts) do
    started_at = Keyword.fetch!(opts, :started_at)

    session
    |> Ecto.Changeset.change(%{
      current_question_position: position,
      current_question_started_at: started_at,
      current_question_ends_at:
        DateTime.add(started_at, session.question_duration_seconds, :second),
      current_question_closed_at: Keyword.get(opts, :closed_at)
    })
    |> Repo.update!()
  end

  defp option_at(questions, question_position, option_position) do
    questions
    |> Enum.find(&(&1.position == question_position))
    |> Map.fetch!(:answer_options)
    |> Enum.find(&(&1.position == option_position))
  end

  defp minutes_ago_usec(minutes), do: DateTime.add(now_usec(), -minutes * 60, :second)

  # The match keeps one question at a time, so the closing of the question left
  # behind by an advance only exists inside that transaction: the statement is
  # what the test can watch. The advance itself also writes
  # `current_question_closed_at`, and it is told apart by the position it sets.
  defp closes_previous_question?(query) do
    String.contains?(query, ~s(UPDATE "game_sessions")) and
      String.contains?(query, ~s("current_question_closed_at" = )) and
      not String.contains?(query, ~s("current_question_position" = ))
  end

  defp capture_queries(fun) do
    handler_id = "match-queries-#{System.unique_integer([:positive])}"
    caller = self()

    :telemetry.attach(
      handler_id,
      [:live_quiz, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == caller, do: send(caller, {:match_query, metadata.query})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    result = fun.()

    {result, collected_match_queries()}
  end

  defp collected_match_queries(acc \\ []) do
    receive do
      {:match_query, query} -> collected_match_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp close_session(session, status) do
    session |> GameSession.status_changeset(status) |> Repo.update!()
  end

  defp participants_of(session) do
    from p in Participant, where: p.game_session_id == ^session.id
  end

  defp active_participations_of(scope) do
    from p in Participant, where: p.user_id == ^scope.user.id, where: is_nil(p.released_at)
  end

  defp hosted_waiting_session(_context) do
    scope = user_scope_fixture()
    quiz = playable_quiz(scope)

    %{
      scope: scope,
      quiz: quiz,
      session: game_session_fixture(%{host: scope.user, quiz: quiz, status: :waiting})
    }
  end

  defp expiring_session(status, at) do
    session = game_session_fixture(%{status: status})

    assert {:ok, away} = Games.mark_host_disconnected(session, at)

    away
  end

  # Closing a room drops its deadline, so a closed room carrying an overdue one
  # has to be forged — it is exactly what the sweep must refuse to pick up.
  defp closed_session_with_deadline(status, at) do
    %{status: status}
    |> game_session_fixture()
    |> GameSession.host_presence_changeset(%{host_disconnected_at: at, expires_at: at})
    |> Repo.update!()
  end

  defp waiting_session(_context) do
    host = user_fixture()

    %{host: host, session: game_session_fixture(%{host: host, status: :waiting})}
  end

  defp fill_session(session, count) do
    for _index <- 1..count, do: participant_fixture(session)
  end

  defp participations_of(scope) do
    from p in Participant, where: p.user_id == ^scope.user.id
  end

  defp minutes_ago(minutes), do: DateTime.add(now(), -minutes * 60, :second)

  defp contains?(value, token) when is_binary(value), do: String.contains?(value, token)
  defp contains?(_value, _token), do: false

  defp host_with_playable_quiz(_context) do
    scope = user_scope_fixture()

    %{scope: scope, quiz: playable_quiz(scope)}
  end

  defp playable_quiz(scope, attrs \\ %{}) do
    quiz = quiz_fixture(scope, attrs)
    question_fixture(scope, quiz)

    quiz
  end

  # A host, a quiz of `count` complete questions and a room waiting on it with
  # somebody signed up — the shape every freezing test starts from.
  defp room_with_questions(count) do
    scope = user_scope_fixture()
    quiz = quiz_fixture(scope, %{title: "Quiz de #{count} pergunta(s)"})

    for index <- 1..count//1 do
      question_fixture(scope, quiz, %{text: "Pergunta #{index} do quiz"})
    end

    %{scope: scope, quiz: quiz, session: room_for(scope, quiz)}
  end

  defp room_for(scope, quiz) do
    session = game_session_fixture(%{host: scope.user, quiz: quiz, status: :waiting})
    participant_fixture(session)

    session
  end

  defp question_ids(quiz) do
    Repo.all(from q in Question, where: q.quiz_id == ^quiz.id, order_by: q.position, select: q.id)
  end

  # The quiz tables are named inside the snapshot ones — `game_session_questions`
  # ends in `questions` — so the check is for the quoted table name, which only
  # matches the real thing.
  defp refute_quiz_tables_queried(fun) do
    handler_id = "snapshot-queries-#{System.unique_integer([:positive])}"
    caller = self()

    :telemetry.attach(
      handler_id,
      [:live_quiz, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == caller, do: send(caller, {:snapshot_query, metadata.query})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    fun.()

    queries = collected_queries()
    assert queries != []

    for query <- queries do
      refute String.contains?(query, ~s("questions")), "consultou questions: #{query}"
      refute String.contains?(query, ~s("answer_options")), "consultou answer_options: #{query}"
      refute String.contains?(query, ~s("quizzes")), "consultou quizzes: #{query}"
    end
  end

  defp collected_queries(acc \\ []) do
    receive do
      {:snapshot_query, query} -> collected_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp hosted_by(scope), do: from(s in GameSession, where: s.host_id == ^scope.user.id)

  defp hosted_any?(scope), do: Repo.exists?(hosted_by(scope))

  # The generator seam is global to the application environment, so only this
  # module — the only one that opens rooms through the context — may set it,
  # and it is always removed at the end of the test.
  defp stub_join_codes(codes) do
    agent = start_supervised!({Agent, fn -> codes end})

    Application.put_env(:live_quiz, :join_code_generator, fn ->
      Agent.get_and_update(agent, fn
        [last] -> {last, [last]}
        [code | rest] -> {code, rest}
      end)
    end)

    on_exit(fn -> Application.delete_env(:live_quiz, :join_code_generator) end)
  end

  # The sandbox lends a single connection, so the tasks below take turns on it
  # rather than truly running at once. What is under test is the outcome the
  # cross-table rules must produce whatever the interleaving is.
  defp in_parallel(items, fun) do
    owner = self()

    items
    |> Enum.map(fn item ->
      Task.async(fn ->
        Sandbox.allow(Repo, owner, self())
        fun.(item)
      end)
    end)
    |> Task.await_many(30_000)
  end

  defp assert_no_query(fun) do
    handler_id = "no-query-#{System.unique_integer([:positive])}"
    caller = self()

    :telemetry.attach(
      handler_id,
      [:live_quiz, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == caller, do: send(caller, {:query, metadata.query})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    fun.()

    refute_received {:query, _query}
  end
end
