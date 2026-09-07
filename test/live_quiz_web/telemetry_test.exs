defmodule LiveQuizWeb.TelemetryTest do
  @moduledoc """
  Que os eventos que a aplicação emite tenham para onde ir.

  Métrica declarada e ninguém escutando é meia frase: o evento sai e não chega
  a lugar nenhum. Este teste cobre as duas metades — o que está descrito em
  `metrics/0`, e o que chega ao log mesmo sem coletor algum.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LiveQuizWeb.Telemetry
  alias LiveQuizWeb.Telemetry.Alerts

  describe "metrics/0" do
    test "descreve todo evento de domínio que a aplicação emite" do
      described = MapSet.new(Telemetry.metrics(), & &1.event_name)

      emitted = [
        [:live_quiz, :mail, :sent],
        [:live_quiz, :mail, :failed],
        [:live_quiz, :mail, :exhausted],
        [:live_quiz, :mail, :expired],
        [:live_quiz, :rate_limit, :refused],
        [:live_quiz, :rate_limit, :overflow],
        [:live_quiz, :rate_limit, :untrusted_origin]
      ]

      # Emitir sem declarar é escrever um número que nenhum reporter recolhe.
      for event <- emitted do
        assert MapSet.member?(described, event),
               "#{inspect(event)} é emitido e não está em metrics/0"
      end
    end

    test "nenhuma tag carrega o corpo, o endereço ou a identidade de alguém" do
      proibidas = [:recipient, :body, :email, :token, :user_id, :participant_id, :session_id]

      for metric <- Telemetry.metrics(), tag <- metric.tags do
        refute tag in proibidas,
               "#{inspect(metric.name)} etiqueta por #{tag}, que identifica uma pessoa " <>
                 "ou vaza um segredo"
      end
    end

    test "cada etiqueta vem de um conjunto que alguém decidiu ser fixo" do
      # Lista de permissão, e não de proibição: uma etiqueta nova só entra
      # depois de alguém responder quantos valores ela pode ter. Uma por sala,
      # por pessoa ou por endereço seria uma série temporal nova a cada partida.
      conhecidas = [
        # do domínio, em LiveQuiz.Games.Telemetry
        :command,
        :result,
        :reason,
        :scored,
        :origin,
        :kind,
        # dos orçamentos, em LiveQuiz.RateLimit
        :bucket,
        # do Phoenix
        :route,
        :event
      ]

      for metric <- Telemetry.metrics(), tag <- metric.tags do
        assert tag in conhecidas,
               "#{inspect(metric.name)} etiqueta por #{tag}, que não está na lista de " <>
                 "etiquetas de cardinalidade conhecida. Quantos valores ela pode ter?"
      end
    end
  end

  describe "reporters/0" do
    test "vem vazia, porque o coletor é decisão de quem implanta" do
      assert Telemetry.reporters() == []
    end

    test "é configuração, não mudança de código" do
      reporter = {Telemetry.Metrics.ConsoleReporter, metrics: []}
      Application.put_env(:live_quiz, Telemetry, reporters: [reporter])

      on_exit(fn -> Application.delete_env(:live_quiz, Telemetry) end)

      assert Telemetry.reporters() == [reporter]
    end
  end

  describe "os eventos que não podem passar em silêncio" do
    setup do
      Alerts.attach()

      :ok
    end

    test "uma mensagem descartada por vencer chega ao log" do
      log =
        capture_log(fn ->
          :telemetry.execute([:live_quiz, :mail, :expired], %{count: 1}, %{
            kind: "reset_password"
          })
        end)

      # Ninguém recebeu, e nada vai tentar de novo. Sem isto, o fato só existia
      # como um contador que ninguém recolhia.
      assert log =~ "reset_password"
      assert log =~ "expired before it was delivered"
      assert log =~ "[error]"
    end

    test "o limitador tendo parado de limitar chega ao log" do
      log =
        capture_log(fn ->
          :telemetry.execute([:live_quiz, :rate_limit, :overflow], %{count: 1}, %{
            bucket: :login_by_origin
          })
        end)

      assert log =~ "login_by_origin"
      assert log =~ "nothing is being limited right now"
      assert log =~ "[error]"
    end

    test "e nada mais é escalado, para que o log continue querendo dizer algo" do
      log =
        capture_log(fn ->
          :telemetry.execute([:live_quiz, :mail, :sent], %{attempts: 1}, %{kind: "confirmation"})

          :telemetry.execute([:live_quiz, :rate_limit, :refused], %{count: 1}, %{
            bucket: :join_by_origin
          })
        end)

      assert log == ""
    end

    test "anexar duas vezes não duplica a linha" do
      Alerts.attach()

      log =
        capture_log(fn ->
          :telemetry.execute([:live_quiz, :mail, :expired], %{count: 1}, %{kind: "confirmation"})
        end)

      assert length(String.split(log, "was dropped")) == 2
    end
  end
end
