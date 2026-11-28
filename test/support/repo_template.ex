defmodule FermixTestSupport.RepoTemplate do
  @moduledoc """
  One database migrated from nothing per app's test run, which every
  `Memory.Repo` a test opens on a new path starts as a copy of.

  A suite opens about 4,000 databases. Migrating each from nothing took about
  80 ms alone and over a second under the suite's load, more than an hour of
  CPU per run, and it grew with every migration. A copy opens in about 2 ms and
  still runs every migration step, each finding its version recorded.

  The template is built through the same `Memory.Repo` start a test uses, so a
  broken migration fails here, before any test runs.
  `FermixCore.Memory.RepoTemplateTest` holds a copy to the schema a migration
  from nothing gives.
  """

  alias FermixCore.Memory.Repo
  alias FermixTestSupport.SafeRm

  @key :repo_template

  @doc "Builds this app's template, points the Repo at it, and removes it after the suite."
  @spec install!() :: :ok
  def install! do
    Application.delete_env(:fermix_core, @key)
    dir = SafeRm.make_tmp_dir!("repo-template")
    path = Path.join(dir, "template.db")
    :ok = build!(path)
    Application.put_env(:fermix_core, @key, path)

    ExUnit.after_suite(fn _result ->
      Application.delete_env(:fermix_core, @key)
      SafeRm.rm_rf(dir)
    end)
  end

  defp build!(path) do
    {:ok, pid} = GenServer.start(Repo, enabled: true, database_path: path)
    :ok = GenServer.stop(pid)
    leftovers = Enum.filter([path <> "-wal", path <> "-shm"], &File.exists?/1)

    if leftovers != [] do
      raise "the template's Repo stopped without checkpointing: #{Enum.join(leftovers, ", ")}"
    end

    :ok
  end
end
