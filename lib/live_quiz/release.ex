defmodule LiveQuiz.Release do
  @moduledoc """
  Tasks that run inside the assembled release, where Mix is not available.

  The demonstration container calls `migrate/0` and `seed/0` on boot instead of
  `mix ecto.migrate` and `mix run priv/repo/seeds.exs`. Nothing here may reach
  for Mix, directly or through a script it evaluates.
  """

  @app :live_quiz

  @doc "Runs every pending migration of every configured repo."
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _result, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Writes the demonstration data, when this environment asked for it.

  It used to evaluate `priv/repo/seeds.exs`, and that script called `Mix.env/0`
  — a build tool that an assembled release does not carry. The demo container
  runs this on boot, so it raised before the server came up; and had Mix been
  there, the script's `:dev` gate would have written nothing into a demo built
  in `:prod`, leaving the documented account missing (R47).

  The data now lives in `LiveQuiz.DemoSeed`, compiled like everything else, and
  what decides whether it runs is `DEMO_SEED` read at boot. Answers `:disabled`
  when the variable does not ask for it, which is the ordinary answer
  everywhere that is not the demonstration: those accounts have published
  passwords.

  Idempotent: running it twice leaves the same data, never a duplicate.
  """
  @spec seed() :: :ok | :disabled
  def seed do
    load_app()

    if LiveQuiz.DemoSeed.enabled?() do
      [repo | _rest] = repos()

      {:ok, result, _apps} =
        Ecto.Migrator.with_repo(repo, fn _repo -> LiveQuiz.DemoSeed.run!() end)

      result
    else
      :disabled
    end
  end

  @doc "Rolls `repo` back down to `version`."
  @spec rollback(module(), integer()) :: :ok
  def rollback(repo, version) do
    load_app()

    {:ok, _result, _apps} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))

    :ok
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
