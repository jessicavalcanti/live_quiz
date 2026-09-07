defmodule LiveQuiz.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LiveQuizWeb.Telemetry,
      LiveQuiz.Repo,
      {DNSCluster, query: Application.get_env(:live_quiz, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: LiveQuiz.PubSub},
      # Who is connected to a room, the grace period of an absent host and the
      # sweep that closes the rooms whose deadline ran out. All three come
      # after the PubSub they use and before the endpoint, so a browser never
      # reaches a room whose presence is not up yet.
      LiveQuiz.Games.Presence,
      LiveQuiz.Games.HostMonitor,
      LiveQuiz.Games.ExpirationSweeper,
      # The deadline of the question that is open is kept by one process per
      # match (AD-40), found through a registry so a match never has two.
      {Registry, keys: :unique, name: LiveQuiz.Games.QuestionTimerRegistry},
      LiveQuiz.Games.QuestionTimerSupervisor,
      # Timers are temporary on purpose — one that dies for a question that is
      # over must not come back — so something has to notice the ones that died
      # for a question that is not. The reconciler is that something, and it is
      # why a lost timer costs a tick instead of a restart (R19).
      LiveQuiz.Games.QuestionTimerReconciler,
      # Start to serve requests, typically the last entry
      LiveQuizWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: LiveQuiz.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      recover_question_timers()
      {:ok, pid}
    end
  end

  # The questions whose deadline ran out while the application was down are
  # settled before anything can connect, and the ones still running get a timer
  # for what is left of their deadline — never for a full new duration (AD-39).
  # It is switched off with the timers themselves, which is what keeps the test
  # suite from sweeping a shared database on every boot.
  defp recover_question_timers do
    if LiveQuiz.Games.QuestionTimer.enabled?() do
      LiveQuiz.Games.QuestionTimerSupervisor.recover()
    end

    :ok
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LiveQuizWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
