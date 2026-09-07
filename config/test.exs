import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :live_quiz, LiveQuiz.Repo,
  username: "postgres",
  password: "postgres",
  hostname: System.get_env("DB_HOST", "localhost"),
  port: 5432,
  database: "live_quiz_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :live_quiz, LiveQuizWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "qYDwZYcRKTuPkH+vHHzYiVzKDqD/SsmyDKW+9gT3mfWtOVAwBOFM/+A+298LlXCY",
  server: false

# Secret for the API JWTs in the test suite.
config :live_quiz, LiveQuiz.Accounts.Guardian,
  secret_key: "1fTLJh9jj4MBtLmE5jCO5ujxW7NT8DYsoplU0tivequcjlouqSKDMhmgE3Luw609"

# The expiration sweeper does not run on its own in the suite: a test that wants
# a sweep calls `ExpirationSweeper.sweep_now/0`.
config :live_quiz, LiveQuiz.Games.ExpirationSweeper, enabled: false

# Question timers neither schedule themselves in the suite nor sweep the database
# on boot: a test that wants the deadline to have passed calls
# `QuestionTimer.fire_now/1`, and one that wants a real deadline starts a timer of
# its own with `enabled: true`.
config :live_quiz, LiveQuiz.Games.QuestionTimer, enabled: false

# Nor does the reconciler run on its own: a test that wants a lost timer put
# back calls `QuestionTimerReconciler.reconcile_now/0`.
config :live_quiz, LiveQuiz.Games.QuestionTimerReconciler, enabled: false

# The grace period of the application's monitor is long on purpose: a test that
# cares about timing starts a monitor of its own with a short window, so no stray
# wait leaks from one test into the next. The reconciliation of presence against
# the database is off for the same reason — a test that wants that pass calls
# `HostMonitor.reconcile_now/1`.
config :live_quiz, LiveQuiz.Games.HostMonitor, grace_period: 60_000, enabled: false

# In test we don't send emails
config :live_quiz, LiveQuiz.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
