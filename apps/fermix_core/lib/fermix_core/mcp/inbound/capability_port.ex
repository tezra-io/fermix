defmodule FermixCore.MCP.Inbound.CapabilityPort do
  @moduledoc """
  Boundary used by the inbound MCP server to list and execute capabilities.

  The server calls this behaviour for both `tools/list` and `tools/call` so
  both operations resolve against the same capability source.
  """

  alias FermixCore.Capabilities.Capability

  @callback list_capabilities() :: {:ok, [Capability.t()]} | {:error, term()}
  @callback execute_capability(String.t(), map(), map()) :: {:ok, term()} | {:error, term()}

  @spec impl() :: module()
  def impl do
    Application.get_env(
      :fermix_core,
      :mcp_inbound_capability_port,
      FermixCore.MCP.Inbound.CapabilityPort.Local
    )
  end
end
