defmodule FermixCore.Capabilities.MCP.Caller do
  @moduledoc """
  Behaviour for MCP tool call dispatchers.

  Dispatch resolves the **source-qualified** identity (`{:plugin, "eden"}` /
  `{:operator, "eden"}`), never a bare server name: two servers may share a
  name, so a bare name can reach the wrong client.

  The fourth argument is the private invoke context `MCP.Capability` mints from
  the executor closure and the turn (M27 §11.1). It carries the turn
  `session_id`, the owning turn pid, the source id, the selected profile, and the
  signed read-only / replay-safe facts. Model arguments never contribute to it —
  they are a separate argument, and the closure is not reachable from them.

  Production stdio servers use `Caller.Anubis`; remote servers use
  `Caller.Remote`, which can only reach the allowlisted `Remote.Proxy`. Tests
  implement this behaviour to stub the transport without spawning clients.
  """

  @type source_id :: {atom(), String.t()}

  @callback call_tool(
              source_id :: source_id(),
              tool :: String.t(),
              args :: map(),
              context :: map()
            ) :: {:ok, term()} | {:error, term()}
end

defmodule FermixCore.Capabilities.MCP.Caller.Anubis do
  @moduledoc """
  Production caller for local stdio servers: resolves the source-qualified
  identity to a registered `Anubis.Client` process via
  `FermixCore.Capabilities.MCP.Registry` and forwards the call.

  A remote source's client is private, so `lookup_client/2` refuses it here —
  the remote rail cannot be reached by accident through the stdio caller.
  """

  @behaviour FermixCore.Capabilities.MCP.Caller

  alias FermixCore.Capabilities.MCP.Registry, as: McpRegistry

  @impl true
  def call_tool({kind, name} = source_id, tool, args, _context)
      when is_atom(kind) and is_binary(name) and is_binary(tool) do
    with {:ok, client} <- McpRegistry.lookup_client(source_id),
         {:ok, response} <- Anubis.Client.call_tool(client, tool, args) do
      {:ok, response}
    end
  end
end

defmodule FermixCore.Capabilities.MCP.Caller.Remote do
  @moduledoc """
  Production caller for remote MCP servers.

  It resolves the source-qualified identity to the published allowlisted
  `Remote.Proxy` — the only reachable handle for a remote source — and hands it
  the private invoke context. Every contract check (profile membership, exact
  tool name, resource scope, budget, pacing) happens inside the proxy,
  immediately before the peer is touched.
  """

  @behaviour FermixCore.Capabilities.MCP.Caller

  alias FermixCore.Capabilities.MCP.Registry, as: McpRegistry
  alias FermixCore.Capabilities.MCP.Remote.Proxy

  @impl true
  def call_tool({kind, name} = source_id, tool, args, context)
      when is_atom(kind) and is_binary(name) and is_binary(tool) and is_map(args) do
    with {:ok, proxy} <- lookup(source_id) do
      Proxy.call(proxy, context, tool, args)
    end
  end

  defp lookup(source_id) do
    case McpRegistry.lookup_proxy(source_id) do
      {:ok, proxy} -> {:ok, proxy}
      {:error, :not_found} -> {:error, :remote_not_connected}
    end
  end
end
