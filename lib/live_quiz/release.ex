defmodule LiveQuiz.Release do
  @moduledoc """
  Tasks that run inside the assembled release, where Mix is not available.

  The demonstration container calls `migrate/0` and `seed/0` on boot instead of
  `mix ecto.migrate` and `mix run priv/repo/seeds.exs`.
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
  Evaluates `priv/repo/seeds.exs` when it is shipped with the release.

  Seeding must stay idempotent: running it twice cannot duplicate data.
  It is a no-op when the file is absent.
  """
  @spec seed() :: :ok
  def seed do
    load_app()

    with path when is_binary(path) <- seeds_path(),
         [repo | _rest] <- repos() do
      {:ok, _result, _apps} =
        Ecto.Migrator.with_repo(repo, fn _repo -> Code.eval_file(path) end)
    end

    :ok
  end

  @doc "Rolls `repo` back down to `version`."
  @spec rollback(module(), integer()) :: :ok
  def rollback(repo, version) do
    load_app()

    {:ok, _result, _apps} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))

    :ok
  end

  defp seeds_path do
    path = Path.join([:code.priv_dir(@app), "repo", "seeds.exs"])
    if File.exists?(path), do: path
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
