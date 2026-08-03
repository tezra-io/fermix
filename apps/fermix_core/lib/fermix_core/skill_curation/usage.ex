defmodule FermixCore.SkillCuration.Usage do
  @moduledoc """
  Durable counts-only skill-usage counters (MILESTONE_26_SKILL_CURATION §6.9).

  One `skill_usage` row per skill in memory.db: `views` increments on a
  successful `skill_view`, `runs` on every finalized `skill_run` invocation.
  Counter loss degrades only staleness measurement, so a failed upsert logs a
  warning and the caller's tool result is returned unchanged; a disabled or
  absent memory repo is a quiet no-op (memory off is a configuration, not a
  failure).
  """

  require Logger

  alias FermixCore.Memory.Repo

  @spec record_view(String.t(), keyword()) :: :ok
  def record_view(skill_name, opts \\ []) when is_binary(skill_name) and skill_name != "" do
    record(skill_name, :view, opts)
  end

  @spec record_run(String.t(), keyword()) :: :ok
  def record_run(skill_name, opts \\ []) when is_binary(skill_name) and skill_name != "" do
    record(skill_name, :run, opts)
  end

  defp record(skill_name, kind, opts) do
    case Repo.enabled_server(Keyword.get(opts, :repo, Repo)) do
      nil -> :ok
      server -> record_on(server, skill_name, kind)
    end
  end

  defp record_on(server, skill_name, kind) do
    case Repo.record_skill_usage(skill_name, kind, DateTime.utc_now(), server: server) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "skill_usage upsert failed for #{skill_name} (#{kind}): #{inspect(reason)}"
        )

        :ok
    end
  end
end
