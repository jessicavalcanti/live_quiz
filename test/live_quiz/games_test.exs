defmodule LiveQuiz.GamesTest do
  use LiveQuiz.DataCase, async: true

  import ExUnit.CaptureLog
  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures
  import LiveQuiz.QuizzesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.JoinCode
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

    test "preserva o título mesmo depois de renomear o quiz", %{scope: scope, quiz: quiz} do
      assert {:ok, session} = Games.create_game_session(scope, quiz.id)
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
