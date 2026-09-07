defmodule LiveQuizWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      | reporters()
    ]

    LiveQuizWeb.Telemetry.Alerts.attach()

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  The reporters that consume `metrics/0`, from configuration.

  There is none by default, and that is the honest default: which collector to
  ship to is a deployment's decision, not a library's. What matters is that
  adding one is configuration rather than a code change —

      config :live_quiz, LiveQuizWeb.Telemetry,
        reporters: [{Telemetry.Metrics.ConsoleReporter, metrics: LiveQuizWeb.Telemetry.metrics()}]

  — and that the handful of events which mean "something is wrong and nobody
  will notice" reach the log even when there is no reporter at all. That is
  `LiveQuizWeb.Telemetry.Alerts`.
  """
  @spec reporters() :: list()
  def reporters do
    :live_quiz
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:reporters, [])
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("live_quiz.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("live_quiz.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("live_quiz.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("live_quiz.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("live_quiz.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # Domain Metrics
      #
      # What a match tells whoever is watching it. Every tag comes from a fixed
      # set in `LiveQuiz.Games.Telemetry`, so the cardinality of the whole
      # domain is a constant — a room id here would be one time series per room.
      summary("live_quiz.games.transition.stop.duration",
        tags: [:command, :result],
        unit: {:native, :millisecond},
        description: "How long a command that moves a match takes, by command and outcome"
      ),
      counter("live_quiz.games.transition.stop.duration",
        tags: [:command, :result, :reason],
        description: "How many commands were refused, and why"
      ),
      summary("live_quiz.games.consolidation.stop.duration",
        tags: [:result],
        unit: {:native, :millisecond},
        description: "How long consolidating one question takes"
      ),
      counter("live_quiz.games.consolidation.stop.duration",
        tags: [:result, :scored],
        description: "How many consolidations did the writing and how many read the standing back"
      ),
      summary("live_quiz.games.question.closed.delay_ms",
        tags: [:origin],
        unit: :millisecond,
        description: "How late a question was closed against its own deadline"
      ),
      summary("live_quiz.games.reconciliation.stop.duration",
        tags: [:kind],
        unit: {:native, :millisecond},
        description: "How long a periodic reconciliation pass takes"
      ),
      sum("live_quiz.games.reconciliation.stop.closed",
        tags: [:kind],
        description: "Questions closed by a reconciliation because nothing else did"
      ),
      sum("live_quiz.games.reconciliation.stop.armed",
        tags: [:kind],
        description: "Timers a reconciliation had to put back"
      ),
      sum("live_quiz.games.reconciliation.stop.opened",
        tags: [:kind],
        description: "Host absences a reconciliation had to open"
      ),
      sum("live_quiz.games.reconciliation.stop.cleared",
        tags: [:kind],
        description: "Stale absence deadlines a reconciliation dropped"
      ),
      sum("live_quiz.games.reconciliation.stop.expired",
        tags: [:kind],
        description: "Rooms closed by the expiration sweep"
      ),

      # The outbox (R07). `kind` comes from the three flows that mail a link, so
      # the cardinality is three — never the address, which is the person, and
      # never the body, which is a live link.
      counter("live_quiz.mail.sent.attempts",
        tags: [:kind],
        description: "Messages delivered, by which flow asked for them"
      ),
      summary("live_quiz.mail.sent.attempts",
        tags: [:kind],
        description: "How many attempts a delivered message took"
      ),
      counter("live_quiz.mail.failed.attempts",
        tags: [:kind],
        description: "Attempts a provider refused"
      ),
      counter("live_quiz.mail.exhausted.attempts",
        tags: [:kind],
        description: "Messages given up on after the last attempt"
      ),
      counter("live_quiz.mail.expired.count",
        tags: [:kind],
        description: "Messages dropped because the link they carry expired first"
      ),

      # The budgets of the open endpoints (R05). `bucket` is one of a fixed set
      # declared by `LiveQuiz.RateLimit`.
      counter("live_quiz.rate_limit.refused.count",
        tags: [:bucket],
        description: "Requests refused for having spent their budget"
      ),
      counter("live_quiz.rate_limit.overflow.count",
        tags: [:bucket],
        description: "Requests let through because the limiter hit its size cap"
      ),
      counter("live_quiz.rate_limit.untrusted_origin.count",
        tags: [:reason],
        description: "Requests whose forwarded headers did not match the declared topology"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {LiveQuizWeb, :count_users, []}
    ]
  end
end
