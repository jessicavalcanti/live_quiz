defmodule LiveQuiz.Games.TelemetryTest do
  @moduledoc """
  What a match reports while it is happening.

  Regression for R44 of the review. The domain logged its failures, and a log
  is where an incident is reconstructed afterwards; these are the events that
  let somebody notice a question closed and never scored, a reconciliation that
  keeps finding work, or a closing that arrives long after its deadline.

  The assertions are as much about the *metadata* as about the events: a room
  id as a metric dimension is a new time series per room, and that is how a
  metrics backend is taken down by a busy afternoon.
  """

  use LiveQuiz.DataCase, async: false

  import LiveQuiz.AccountsFixtures
  import LiveQuiz.GamesFixtures

  alias LiveQuiz.Accounts.Scope
  alias LiveQuiz.Games
  alias LiveQuiz.Games.GameSession
  alias LiveQuiz.Games.QuestionTimer
  alias LiveQuiz.Games.QuestionTimerReconciler
  alias LiveQuiz.Games.Telemetry

  @transition [:live_quiz, :games, :transition, :stop]
  @consolidation [:live_quiz, :games, :consolidation, :stop]
  @closed [:live_quiz, :games, :question, :closed]
  @reconciliation [:live_quiz, :games, :reconciliation, :stop]

  describe "os rótulos são um conjunto fixo" do
    test "comandos, origens e varreduras são átomos conhecidos" do
      assert :advance in Telemetry.commands()
      assert :close in Telemetry.commands()
      assert :finish in Telemetry.commands()

      assert :host in Telemetry.origins()
      assert :timeout in Telemetry.origins()
      assert :everybody_answered in Telemetry.origins()

      assert :question_timer in Telemetry.kinds()
      assert :host_absence in Telemetry.kinds()
      assert :expiration in Telemetry.kinds()
    end
  end

  describe "o rótulo do motivo é sempre limitado" do
    setup :listen

    test "um changeset vira :invalid em vez de virar uma dimensão nova" do
      Telemetry.transition(:join, fn -> {:error, %Ecto.Changeset{}} end)

      assert_receive {:event, @transition, _measurements, metadata}
      assert metadata.result == :error
      assert metadata.reason == :invalid
    end

    test "um :ok sem valor é um resultado como outro qualquer" do
      Telemetry.transition(:leave, fn -> :ok end)

      assert_receive {:event, @transition, _measurements, %{result: :ok, reason: nil}}
    end

    test "um retorno que não é nem :ok nem erro não inventa motivo" do
      Telemetry.transition(:answer, fn -> :something_else end)

      assert_receive {:event, @transition, _measurements, %{result: :ok, reason: nil}}
    end

    test "uma pergunta sem prazo não reporta atraso negativo nem nulo" do
      Telemetry.question_closed(:host, nil, DateTime.utc_now())

      assert_receive {:event, @closed, %{delay_ms: 0}, %{origin: :host}}
    end
  end

  describe "transições" do
    setup [:open_question, :listen]

    test "o avanço reporta duração e resultado", %{scope: scope, session: session} do
      assert {:ok, advanced} = Games.advance_question(scope, session, 1)
      Games.QuestionTimer.stop(advanced.id)

      assert_receive {:event, @transition, measurements, metadata}
      assert metadata.command == :advance
      assert metadata.result == :ok
      assert is_nil(metadata.reason)
      assert measurements.duration > 0
    end

    test "o comando recusado reporta o motivo, não o objeto", %{
      scope: scope,
      session: session
    } do
      assert Games.close_question(scope, session, expected_position: 99) == {:error, :stale}

      assert_receive {:event, @transition, _measurements, metadata}
      assert metadata.command == :close
      assert metadata.result == :error
      assert metadata.reason == :stale
    end

    test "nenhum identificador de sala ou de conta vira dimensão", %{
      scope: scope,
      session: session
    } do
      assert {:ok, _closed} = Games.close_question(scope, session)

      assert_receive {:event, @transition, _measurements, metadata}

      assert Map.keys(metadata) |> Enum.sort() == [:command, :reason, :result]

      refute session.id in Map.values(metadata)
      refute scope.user.id in Map.values(metadata)
    end
  end

  describe "consolidação" do
    setup [:open_question, :listen]

    test "a primeira consolidação marca que escreveu", %{scope: scope, session: session} do
      assert {:ok, _closed} = Games.close_question(scope, session)

      assert_receive {:event, @consolidation, measurements, metadata}
      assert metadata.result == :ok
      assert metadata.scored == true
      assert measurements.duration > 0
    end

    test "a segunda lê o mesmo ranking de volta e diz isso", %{scope: scope, session: session} do
      assert {:ok, closed} = Games.close_question(scope, session)
      assert {:ok, _ranking} = Games.score_closed_question(closed, 1)

      assert_receive {:event, @consolidation, _first, %{scored: true}}
      assert_receive {:event, @consolidation, _second, %{scored: false}}
    end

    test "a consolidação recusada reporta o motivo", %{session: session} do
      # A pergunta ainda está aberta: consolidar agora é recusado, e é esse
      # motivo que precisa chegar a quem observa.
      assert Games.score_closed_question(session, 1) == {:error, :question_open}

      assert_receive {:event, @consolidation, _measurements, metadata}
      assert metadata.result == :error
      assert metadata.reason == :question_open
      assert metadata.scored == false
    end
  end

  describe "atraso do encerramento" do
    setup [:open_question, :listen]

    test "o host que encerra antes do prazo não reporta atraso", %{
      scope: scope,
      session: session
    } do
      assert {:ok, _closed} = Games.close_question(scope, session)

      assert_receive {:event, @closed, %{delay_ms: 0}, %{origin: :host}}
    end

    test "o prazo vencido há um minuto reporta o minuto", %{session: session} do
      overdue(session, 60)

      assert {:ok, _closed} = Games.close_question_by_timeout(session.id, 1)

      assert_receive {:event, @closed, %{delay_ms: delay}, %{origin: :timeout}}
      assert delay >= 60_000
    end

    test "todo mundo ter respondido também reporta a origem", %{session: session} do
      participant = participant_fixture(session)
      option = session.id |> first_option()

      assert {:ok, %{closed?: true}} =
               Games.answer_question(participant, option.id, [participant.id])

      assert_receive {:event, @closed, _measurements, %{origin: :everybody_answered}}
    end
  end

  describe "varreduras periódicas" do
    setup [:open_question, :listen]

    test "a reconciliação de timers reporta o que rearmou", %{session: session} do
      kill_timer(session)

      reconciler =
        start_supervised!(
          {QuestionTimerReconciler, name: nil, lister: fn -> [reload(session)] end}
        )

      assert %{armed: 1} = QuestionTimerReconciler.reconcile_now(reconciler)

      assert_receive {:event, @reconciliation, measurements, metadata}
      assert metadata.kind == :question_timer
      assert measurements.armed == 1
      assert measurements.closed == 0
      assert measurements.duration > 0
    end

    test "a reconciliação de ausência reporta o que abriu", %{session: session} do
      {:ok, claimed, _id} = Games.claim_host_connection(Scope.for_user(host_of(session)), session)

      monitor =
        start_supervised!(
          {LiveQuiz.Games.HostMonitor,
           name: nil, grace_period: 60_000, lister: fn -> [reload(claimed)] end}
        )

      assert %{opened: 1} = LiveQuiz.Games.HostMonitor.reconcile_now(monitor)

      assert_receive {:event, @reconciliation, measurements, %{kind: :host_absence}}
      assert measurements.opened == 1
      assert measurements.cleared == 0
    end

    test "a varredura de expiração reporta quantas salas fechou" do
      session = game_session_fixture(%{status: :waiting}) |> overdue_host_absence()

      sweeper =
        start_supervised!(
          {LiveQuiz.Games.ExpirationSweeper, name: nil, lister: fn -> [session] end}
        )

      assert [_expired] = LiveQuiz.Games.ExpirationSweeper.sweep_now(sweeper)

      assert_receive {:event, @reconciliation, measurements, %{kind: :expiration}}
      assert measurements.expired == 1
    end
  end

  defp open_question(_context) do
    host = user_fixture()
    scope = Scope.for_user(host)
    session = game_session_fixture(%{host: host, status: :in_progress})
    snapshot_fixture(session, count: 2)

    {:ok, opened} = Games.advance_question(scope, session, nil)
    on_exit(fn -> QuestionTimer.stop(opened.id) end)

    %{scope: scope, host: host, session: opened}
  end

  # Attached per test and detached with it, so no handler outlives the process
  # it sends to.
  defp listen(_context) do
    parent = self()
    id = {__MODULE__, System.unique_integer([:positive])}

    :telemetry.attach_many(
      id,
      [@transition, @consolidation, @closed, @reconciliation],
      fn event, measurements, metadata, _config ->
        send(parent, {:event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    :ok
  end

  defp overdue(%GameSession{id: id}, seconds) do
    past = DateTime.add(DateTime.utc_now(), -seconds, :second)

    Repo.update_all(from(s in GameSession, where: s.id == ^id),
      set: [current_question_started_at: past, current_question_ends_at: past]
    )
  end

  defp kill_timer(%GameSession{id: id}) do
    :ok = QuestionTimer.stop(id)
    assert is_nil(QuestionTimer.whereis(id))
  end

  defp first_option(session_id) do
    LiveQuiz.Games.GameSessionAnswerOption
    |> join(:inner, [o], q in LiveQuiz.Games.GameSessionQuestion,
      on: q.id == o.game_session_question_id
    )
    |> where([o, q], q.game_session_id == ^session_id and q.position == 1)
    |> order_by([o], asc: o.position)
    |> limit(1)
    |> Repo.one!()
  end

  defp host_of(%GameSession{host_id: host_id}), do: Repo.get!(LiveQuiz.Accounts.User, host_id)

  defp reload(%GameSession{id: id}), do: Repo.get!(GameSession, id)
end
