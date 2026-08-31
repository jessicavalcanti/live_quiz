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
  hostname: "localhost",
  port: String.to_integer(System.get_env("DB_PORT", "5432")),
  database: "live_quiz_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :live_quiz, LiveQuizWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "qYDwZYcRKTuPkH+vHHzYiVzKDqD/SsmyDKW+9gT3mfWtOVAwBOFM/+A+298LlXCY",
  server: false

# Segredo dos JWTs da API na suíte de testes.
config :live_quiz, LiveQuiz.Accounts.Guardian,
  secret_key: "1fTLJh9jj4MBtLmE5jCO5ujxW7NT8DYsoplU0tivequcjlouqSKDMhmgE3Luw609"

# O sweeper de expiracao nao roda sozinho na suite: os testes chamam
# `ExpirationSweeper.sweep_now/0` quando querem uma varredura.
config :live_quiz, LiveQuiz.Games.ExpirationSweeper, enabled: false

# A carencia do monitor da aplicacao fica longa de proposito: quem testa
# temporizacao sobe um monitor proprio, com janela curta, e nenhuma espera
# solta sobra de um teste para o outro.
config :live_quiz, LiveQuiz.Games.HostMonitor, grace_period: 60_000

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
