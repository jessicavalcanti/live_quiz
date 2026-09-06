defmodule LiveQuiz.Games.ExpirationSweeperTest do
  # The sweep runs inside the sweeper process, so the sandbox has to be shared.
  use LiveQuiz.DataCase, async: false

  import ExUnit.CaptureLog
  import LiveQuiz.GamesFixtures

  alias LiveQuiz.Games
  alias LiveQuiz.Games.ExpirationSweeper
  alias LiveQuiz.Games.GameSession

  describe "configuração" do
    test "o tique é de dez segundos" do
      assert ExpirationSweeper.tick() == :timer.seconds(10)
    end

    test "a varredura periódica fica desligada na suíte" do
      refute ExpirationSweeper.enabled?()
    end
  end

  describe "sweep_now/0" do
    test "expira a sala cujo prazo venceu e avisa os inscritos" do
      session = expiring_session(:waiting, minutes_ago(6))
      :ok = Games.subscribe(session.id)

      assert [expired] = ExpirationSweeper.sweep_now()

      assert expired.id == session.id
      assert expired.status == :expired
      assert_receive {:game_expired, %GameSession{id: id, status: :expired}}, 2_000
      assert id == session.id

      assert reload(session).status == :expired
    end

    test "expira também a sala que já estava em andamento" do
      session = expiring_session(:in_progress, minutes_ago(6))

      assert [expired] = ExpirationSweeper.sweep_now()

      assert expired.id == session.id
      assert expired.status == :expired
    end

    test "dispensa todo mundo da sala expirada" do
      session = expiring_session(:waiting, minutes_ago(6))
      participant = participant_fixture(session)

      assert [_expired] = ExpirationSweeper.sweep_now()

      refute is_nil(Repo.reload!(participant).released_at)
    end

    test "não toca na sala com prazo ainda em curso" do
      session = expiring_session(:waiting, now())

      assert ExpirationSweeper.sweep_now() == []
      assert reload(session).status == :waiting
    end

    test "não toca na sala sem prazo nenhum" do
      session = game_session_fixture(%{status: :waiting})

      assert ExpirationSweeper.sweep_now() == []
      assert reload(session).status == :waiting
    end

    test "ignora a sala já encerrada com prazo vencido" do
      cancelled = closed_session_with_deadline(:cancelled, minutes_ago(30))
      finished_at = cancelled.finished_at

      assert ExpirationSweeper.sweep_now() == []

      unchanged = reload(cancelled)
      assert unchanged.status == :cancelled
      assert unchanged.finished_at == finished_at
    end

    test "uma varredura sem nada vencido não quebra nem derruba o processo" do
      assert ExpirationSweeper.sweep_now() == []
      assert ExpirationSweeper.sweep_now() == []
      assert Process.alive?(Process.whereis(ExpirationSweeper))
    end

    test "expira várias salas de uma vez" do
      sessions = for _index <- 1..3, do: expiring_session(:waiting, minutes_ago(6))

      expired = ExpirationSweeper.sweep_now()

      assert Enum.sort(Enum.map(expired, & &1.id)) == Enum.sort(Enum.map(sessions, & &1.id))
      assert Enum.all?(expired, &(&1.status == :expired))
    end
  end

  describe "recuperação após reinício" do
    test "o prazo vencido durante a indisponibilidade é aplicado sem prazo novo" do
      # A aplicação teria caído às 09h58 e voltado às 10h05: o prazo venceu às
      # 10h00, com a aplicação fora do ar, e a sala não ganha cinco minutos novos.
      away_at = minutes_ago(37)
      session = expiring_session(:waiting, away_at)
      expires_at = reload(session).expires_at

      assert [expired] = ExpirationSweeper.sweep_now()

      assert expired.id == session.id
      assert expired.status == :expired
      assert DateTime.compare(expires_at, DateTime.utc_now()) == :lt
      refute is_nil(expired.finished_at)
      assert is_nil(expired.expires_at)
    end

    test "a sala válida sobrevive à varredura de boot" do
      session = game_session_fixture(%{status: :waiting})
      participants = for _index <- 1..3, do: participant_fixture(session)

      assert ExpirationSweeper.sweep_now() == []

      assert reload(session).status == :waiting
      assert Enum.all?(participants, &is_nil(Repo.reload!(&1).released_at))
    end
  end

  describe "tolerância a falha" do
    test "uma sala que explode não interrompe as demais nem derruba o sweeper" do
      session = expiring_session(:waiting, minutes_ago(6))
      # Uma sala com id inválido faz a consulta de encerramento estourar, que é
      # a falha que a varredura tem de absorver.
      broken = %GameSession{id: "sala inexistente"}

      sweeper =
        start_supervised!(
          {ExpirationSweeper, name: nil, lister: fn -> [broken, reload(session)] end}
        )

      log =
        capture_log(fn ->
          assert [expired] = ExpirationSweeper.sweep_now(sweeper)
          assert expired.id == session.id
        end)

      assert log =~ "sweeper failed expiring room"
      assert Process.alive?(sweeper)
      assert reload(session).status == :expired
    end

    test "a sala fechada entre a listagem e o encerramento é ignorada" do
      cancelled = closed_session_with_deadline(:cancelled, minutes_ago(30))

      sweeper =
        start_supervised!({ExpirationSweeper, name: nil, lister: fn -> [cancelled] end})

      assert ExpirationSweeper.sweep_now(sweeper) == []
      assert reload(cancelled).status == :cancelled
    end

    test "uma listagem que explode é registrada e o sweeper continua vivo" do
      sweeper =
        start_supervised!(
          {ExpirationSweeper, name: nil, lister: fn -> raise "banco fora do ar" end}
        )

      log = capture_log(fn -> assert ExpirationSweeper.sweep_now(sweeper) == [] end)

      assert log =~ "sweeper failed listing the expired rooms"
      assert Process.alive?(sweeper)
    end
  end

  describe "varredura periódica" do
    test "o tique configurado expira a sala sem ninguém pedir" do
      session = expiring_session(:waiting, minutes_ago(6))
      :ok = Games.subscribe(session.id)

      start_supervised!({ExpirationSweeper, name: nil, enabled: true, tick: 10})

      assert_receive {:game_expired, %GameSession{id: id}}, 2_000
      assert id == session.id
    end
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
    |> Ecto.Changeset.change(%{
      status: status,
      finished_at: at,
      host_disconnected_at: at,
      expires_at: at
    })
    |> Repo.update!()
  end

  defp reload(session), do: Repo.get!(GameSession, session.id)

  defp minutes_ago(minutes), do: DateTime.add(now(), -minutes * 60, :second)
end
