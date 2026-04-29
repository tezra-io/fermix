defmodule FermixCore.Capabilities.MCP.Supervisor do
  @moduledoc """
  Top-level MCP supervisor. Owns the per-server discovery + registration
  GenServers, the `MCP.Registry` client lookup table, and the
  `MCP.Naming` ETS table.

  The list of configured MCP servers is read from `Application.get_env(
  :fermix_core, :mcp_servers, [])` at boot. A server config map (parsed
  by `MCP.Config`) carries `name`, `approved?`, `command`, `args`,
  `env`, and `tools_overrides`. This stage owns discovery + capability
  registration; spawning external `npx` subprocesses through Hermes is
  intentionally left for the operator-facing follow-up — server entries
  with no `client_pid` discover via the configured `Discoverer`.

  One bad server isolates inside its own subtree. The other servers
  keep running. The supervisor uses `:rest_for_one` only between the
  shared infrastructure (Naming + Registry) and the per-server children;
  per-server children themselves are `:one_for_one`.
  """

  use Supervisor
  require Logger

  alias FermixCore.Capabilities.MCP.Naming
  alias FermixCore.Capabilities.MCP.Registry, as: McpRegistry
  alias FermixCore.Capabilities.MCP.Server, as: McpServer

  @type opt ::
          {:name, atom()}
          | {:servers, [map()]}
          | {:capability_registry, GenServer.server()}
          | {:mcp_registry, GenServer.server() | nil}

  @spec start_link([opt()]) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Naming.init()

    capability_registry =
      Keyword.get(opts, :capability_registry, FermixCore.Capabilities.Registry)

    mcp_registry_name = Keyword.get(opts, :mcp_registry, McpRegistry)
    servers = Keyword.get(opts, :servers, default_servers())

    children =
      [{McpRegistry, name: mcp_registry_name}] ++
        Enum.map(servers, &child_spec_for(&1, capability_registry, mcp_registry_name))

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp child_spec_for(server, capability_registry, mcp_registry_name) do
    %{
      id: {:mcp_server_supervisor, server.name},
      start:
        {Supervisor, :start_link,
         [
           [
             Supervisor.child_spec(
               {McpServer, server_opts(server, capability_registry, mcp_registry_name)},
               id: {:mcp_server, server.name},
               restart: :permanent
             )
           ],
           [strategy: :one_for_one, max_restarts: 3, max_seconds: 60]
         ]},
      type: :supervisor,
      restart: :temporary
    }
  end

  defp server_opts(server, capability_registry, mcp_registry_name) do
    [
      server_name: server.name,
      approved?: Map.get(server, :approved?, false),
      tools_overrides: Map.get(server, :tools_overrides, %{}),
      capability_registry: capability_registry,
      mcp_registry: mcp_registry_name
    ]
    |> maybe_put(:client, Map.get(server, :client))
    |> maybe_put(:discoverer, Map.get(server, :discoverer))
    |> maybe_put(:caller, Map.get(server, :caller))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp default_servers do
    Application.get_env(:fermix_core, :mcp_servers, [])
  end
end
