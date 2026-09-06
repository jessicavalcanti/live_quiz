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
      # Start to serve requests, typically the last entry
      LiveQuizWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: LiveQuiz.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LiveQuizWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
