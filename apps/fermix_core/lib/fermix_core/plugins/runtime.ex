defmodule FermixCore.Plugins.Runtime do
  @moduledoc """
  Refreshes plugin-derived runtime surfaces after catalog/config/auth changes.
  """

  alias FermixCore.Agents.MainAgent
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Plugins.Capabilities
  alias FermixCore.Realtime.SessionSupervisor

  @type reload_summary :: %{
          capabilities: map() | :skipped,
          skills: map() | :handled_by_main_agent | :skipped,
          main_agent: map() | :skipped,
          realtime: map() | :skipped
        }

  @spec reload(keyword()) :: {:ok, reload_summary()} | {:error, term()}
  def reload(opts \\ []) when is_list(opts) do
    capability_registry = Keyword.get(opts, :capability_registry, CapabilityRegistry)
    skill_registry = Keyword.get(opts, :skill_registry, SkillRegistry)
    main_agent = Keyword.get(opts, :main_agent, MainAgent)
    realtime_supervisor = Keyword.get(opts, :realtime_supervisor, SessionSupervisor)

    with {:ok, capabilities} <- reload_capabilities(capability_registry),
         {:ok, main_agent_summary} <- reload_main_agent(main_agent),
         {:ok, skills} <- reload_skills(skill_registry, main_agent_summary),
         {:ok, realtime} <- reload_realtime(realtime_supervisor) do
      {:ok,
       %{
         capabilities: capabilities,
         skills: skills,
         main_agent: main_agent_summary,
         realtime: realtime
       }}
    end
  end

  defp reload_capabilities(server) do
    if alive?(server), do: Capabilities.reload(server), else: {:ok, :skipped}
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
