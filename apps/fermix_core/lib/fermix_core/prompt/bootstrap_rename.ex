defmodule FermixCore.Prompt.BootstrapRename do
  @moduledoc """
  One-time on-disk rename of bootstrap `AGENTS.md` files to `FERMIX.md`.

  Companion to the `fermix_md` resource-type migration in `Memory.Repo`:
  the operating-rules bootstrap file moved from `AGENTS.md` to `FERMIX.md`
  to avoid collision with the workspace `AGENTS.md` convention that coding
  agents read as project context. This walks the per-agent bootstrap
  directories and renames the legacy file so operator edits carry over.

  Idempotent: renames `<bootstrap_dir>/<agent_id>/AGENTS.md` to `FERMIX.md`
  only when the legacy file exists and the new file does not. Safe to call
  on every boot — it no-ops once the rename has happened, and on fresh
  installs (no legacy files) it does nothing.
  """

  alias FermixCore.Prompt.BootstrapPaths

  require Logger

  @legacy_basename "AGENTS.md"
  @current_basename "FERMIX.md"

  @spec run(keyword()) :: :ok
  def run(opts \\ []) when is_list(opts) do
    dir = BootstrapPaths.bootstrap_dir(opts)

    case File.ls(dir) do
      {:ok, entries} ->
        Enum.each(entries, &rename_agent_file(dir, &1))

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("bootstrap rename scan failed for #{dir}: #{inspect(reason)}")
    end

    :ok
  end

  defp rename_agent_file(dir, agent_id) do
    legacy = Path.join([dir, agent_id, @legacy_basename])
    current = Path.join([dir, agent_id, @current_basename])

    if File.regular?(legacy) and not File.exists?(current) do
      rename(legacy, current)
    end
  end

  defp rename(legacy, current) do
    case File.rename(legacy, current) do
      :ok ->
        Logger.info("renamed bootstrap file #{legacy} -> #{current}")

      {:error, reason} ->
        Logger.warning("bootstrap rename failed #{legacy} -> #{current}: #{inspect(reason)}")
    end
  end
end
