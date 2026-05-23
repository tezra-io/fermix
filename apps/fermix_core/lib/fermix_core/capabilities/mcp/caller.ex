defmodule FermixCore.Capabilities.MCP.Caller do
  @moduledoc """
  Behaviour for MCP tool call dispatchers.

  Production uses `FermixCore.Capabilities.MCP.Caller.Anubis`, which
  delegates to a per-server `Anubis.Client`. Tests can implement
  this behaviour to stub out the MCP transport without spawning real
  client processes.
  """

  @callback call_tool(server :: String.t(), tool :: String.t(), args :: map()) ::
              {:ok, term()} | {:error, term()}
end

defmodule FermixCore.Capabilities.MCP.Caller.Anubis do
  @moduledoc """
  Production caller that resolves the server name to a registered
  `Anubis.Client` process via `FermixCore.Capabilities.MCP.Registry`
  and forwards the call.
  """

  @behaviour FermixCore.Capabilities.MCP.Caller

  alias FermixCore.Capabilities.MCP.Registry, as: McpRegistry

  @impl true
  def call_tool(server, tool, args) when is_binary(server) and is_binary(tool) do
    with {:ok, client} <- McpRegistry.lookup_client(server),
         {:ok, response} <- Anubis.Client.call_tool(client, tool, args) do
      {:ok, response}
    end
  end
end
