defmodule FermixCore.MCP.Inbound.Exposure do
  @moduledoc """
  Pure gate for exposing registry capabilities over inbound MCP.

  The inbound server reads from the existing `FermixCore.Capabilities.Registry`
  and then applies this predicate. There is no inbound-only registry.
  """

  alias FermixCore.Capabilities.Capability
  alias FermixCore.MCP.Inbound.Config

  @spec expose_for_inbound([Capability.t()], Config.t()) :: [Capability.t()]
  def expose_for_inbound(_capabilities, %Config{enabled?: false}), do: []

  def expose_for_inbound(capabilities, %Config{} = config) when is_list(capabilities) do
    Enum.filter(capabilities, &exposed?(&1, config))
  end

  @spec exposed?(Capability.t(), Config.t()) :: boolean()
  def exposed?(%Capability{name: name} = capability, %Config{} = config) do
    case Map.get(config.tool_overrides, name) do
      %{exposed: false} -> false
      %{exposed: true} -> true
      _override -> passes_default_gate?(capability, config)
    end
  end

  @spec to_mcp_tool_descriptor(Capability.t(), %{String.t() => Config.tool_override()}) :: map()
  def to_mcp_tool_descriptor(%Capability{} = capability, overrides) when is_map(overrides) do
    override = Map.get(overrides, capability.name, %{})

    %{
      "name" => capability.name,
      "description" => Map.get(override, :description_override, capability.description),
      "inputSchema" => capability.parameters
    }
  end

  defp passes_default_gate?(%Capability{} = capability, %Config{} = config) do
    capability.kind in config.expose_kinds and
      capability.policy_class in config.expose_policy_classes and
      not capability.hidden_from_agent? and
      allowlisted?(capability.name, config.allowed_tools) and
      not denied?(capability.name, config.denied_tools)
  end

  defp allowlisted?(_name, []), do: true
  defp allowlisted?(name, allowed_tools), do: name in allowed_tools

  defp denied?(name, denied_tools), do: name in denied_tools
end
