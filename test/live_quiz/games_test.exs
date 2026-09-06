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
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.JoinCode
  alias LiveQuiz.Games.Participant
  alias LiveQuiz.Games.ParticipantToken
  alias LiveQuiz.Quizzes

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
    end

    test "recusa que um terceiro autenticado inicie a sala", %{session: session} do
      assert {:error, :unauthorized} = Games.start_game_session(user_scope_fixture(), session, 1)
      assert Repo.get!(GameSession, session.id).status == :waiting
    end

    test "recusa iniciar uma sala já iniciada", %{scope: scope, session: session} do
      started = start_session(session)

      assert {:error, :invalid_transition} = Games.start_game_session(scope, started, 1)
      assert Repo.get!(GameSession, session.id).started_at == started.started_at
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

    test "duas chamadas de início produzem um único started_at", %{
      scope: scope,
      session: session
    } do
      participant_fixture(session)

      results =
        in_parallel([1, 2], fn _attempt -> Games.start_game_session(scope, session, 1) end)

      started =
        Enum.filter(results, fn
          {:ok, %GameSession{}} -> true
          _refused -> false
        end)

      assert [{:ok, %GameSession{} = single}] = started
      assert Enum.count(results, &(&1 == {:error, :invalid_transition})) == 1

      current = Repo.get!(GameSession, session.id)
      assert current.status == :in_progress
      assert current.started_at == single.started_at
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

  defp start_session(session) do
    session |> GameSession.status_changeset(:in_progress) |> Repo.update!()
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
