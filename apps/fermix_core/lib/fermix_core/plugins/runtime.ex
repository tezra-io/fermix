defmodule FermixCore.Plugins.Runtime do
  @moduledoc """
  Refreshes plugin-derived runtime surfaces after catalog/config/auth changes.
  """

  alias FermixCore.Agents.MainAgent
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.MCP.Supervisor, as: McpSupervisor
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Plugins.Capabilities
  alias FermixCore.Realtime.SessionSupervisor
  alias FermixCore.Setup.ConfigStore

  @type reload_summary :: %{
          capabilities: map() | :skipped,
          mcp: map() | :skipped,
          skills: map() | :handled_by_main_agent | :skipped,
          main_agent: map() | :skipped,
          realtime: map() | :skipped
        }

  @doc """
  Re-read persisted config (`config.toml`) into app env, then `reload/0`.

  The daemon's `plugins_apply` entry point (§11 two-VM reality): a sibling CLI
  VM mutates the persisted config/plugin store on disk, then asks the running
  daemon to re-apply it from disk.
  """
  @spec apply_persisted() :: {:ok, reload_summary()} | {:error, term()}
  def apply_persisted do
    with :ok <- ConfigStore.bootstrap_runtime_config(), do: reload()
  end

  @spec reload(keyword()) :: {:ok, reload_summary()} | {:error, term()}
  def reload(opts \\ []) when is_list(opts) do
    capability_registry = Keyword.get(opts, :capability_registry, CapabilityRegistry)
    skill_registry = Keyword.get(opts, :skill_registry, SkillRegistry)
    main_agent = Keyword.get(opts, :main_agent, MainAgent)
    realtime_supervisor = Keyword.get(opts, :realtime_supervisor, SessionSupervisor)
    mcp_supervisor = Keyword.get(opts, :mcp_supervisor, McpSupervisor)

    # Each surface refreshes independently. The agent-facing refresh — drop the
    # MainAgent's cached prompt — runs FIRST and unconditionally, so a failure
    # reconciling capabilities/MCP/skills can never leave the agent's prompt
    # staler than the registry. We then run every remaining step regardless of
    # the others' outcome (no short-circuit) and surface any failure in the
    # return value, instead of silently dropping it. A failed main-agent skill
    # reload falls back to a direct skill-registry reload.
    invalidate_runtime_context(main_agent)

    main_agent_outcome = reload_main_agent(main_agent)

    [
      capabilities: reload_capabilities(capability_registry),
      mcp: reload_mcp(mcp_supervisor),
      main_agent: main_agent_outcome,
      skills: reload_skills(skill_registry, ok_value(main_agent_outcome)),
      realtime: reload_realtime(realtime_supervisor)
    ]
    |> finalize_reload()
  end

  # Unwrap a step's `{:ok, value}` for the summary and for feeding the skill
  # reload; any non-ok outcome collapses to `:skipped` so the skill reload
  # falls back to a direct skill-registry reload rather than propagating nil.
  defp ok_value({:ok, value}), do: value
  defp ok_value(_other), do: :skipped

  defp finalize_reload(outcomes) do
    summary = Map.new(outcomes, fn {key, outcome} -> {key, ok_value(outcome)} end)
    failures = for {key, {:error, reason}} <- outcomes, do: {key, reason}

    case failures do
      [] -> {:ok, summary}
      failures -> {:error, {:reload_incomplete, failures}}
    end
  end

  defp reload_capabilities(server) do
    if alive?(server), do: Capabilities.reload(server), else: {:ok, :skipped}
  end

  # Diff the running MCP children against the enabled set: enabling an mcp
  # plugin starts its child, disabling stops it (M8.1 §4.5 gap 3). No-op
  # when the MCP supervisor is not running (boot, CLI-only VM, tests).
  defp reload_mcp(server) do
    if alive?(server), do: McpSupervisor.reload(server, []), else: {:ok, :skipped}
  end

  # A plugin enable/disable/logout must reach the agent's very next turn:
  # drop the MainAgent-cached RuntimeContext so it rebuilds its tool list
  # from the registry. No-op when the MainAgent is not running (boot,
  # CLI-only VM, tests).
  defp invalidate_runtime_context(server) do
    if alive?(server) do
      MainAgent.invalidate_runtime_context(server, :plugins_changed)
    else
      :ok
    end
  end

  defp reload_main_agent(server) do
    if alive?(server), do: MainAgent.reload_skills(server), else: {:ok, :skipped}
  end

  defp reload_skills(_server, summary) when is_map(summary), do: {:ok, :handled_by_main_agent}

  defp reload_skills(server, :skipped) do
    if alive?(server), do: SkillRegistry.reload(server), else: {:ok, :skipped}
  end

  defp reload_realtime(nil), do: {:ok, :skipped}

  defp reload_realtime(server) do
    if alive?(server), do: SessionSupervisor.reload_sessions(server), else: {:ok, :skipped}
  end

  defp alive?(nil), do: false
  defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp alive?(name) when is_atom(name), do: Process.whereis(name) != nil
  defp alive?(_server), do: false
end
