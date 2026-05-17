defmodule FermixCore.Capabilities.MCP.Supervisor do
  @moduledoc """
  Top-level MCP supervisor. Owns the per-server discovery + registration
  GenServers, the `MCP.Registry` client lookup table, and the
  `MCP.Naming` ETS table.

  The list of configured MCP servers is read from `Application.get_env(
  :fermix_core, :mcp_servers, [])` at boot. A server config map (parsed
  by `MCP.Config`) carries `name`, `approved?`, `command`, `args`,
  `env`, and `tools_overrides`.

  Each per-server sub-supervisor contains the Hermes client + transport
  pair (built by the configured `:hermes_starter`, default
  `HermesStarter.Default`) plus the `MCP.Server` discovery process. The
  three are linked under `:one_for_all`, so a transport crash bounces the
  client and the discovery process together.

  One bad server isolates inside its own subtree. The other servers keep
  running.
  """

  use Supervisor
  require Logger

  alias FermixCore.Capabilities.MCP.HermesStarter
  alias FermixCore.Capabilities.MCP.Naming
  alias FermixCore.Capabilities.MCP.Registry, as: McpRegistry
  alias FermixCore.Capabilities.MCP.Server, as: McpServer
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Sandbox.Env, as: SandboxEnv

  @type opt ::
          {:name, atom()}
          | {:servers, [map()]}
          | {:capability_registry, GenServer.server()}
          | {:mcp_registry, GenServer.server() | nil}
          | {:hermes_starter, module()}

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
    hermes_starter = Keyword.get(opts, :hermes_starter, HermesStarter.Default)
    servers = Keyword.get(opts, :servers, default_servers())

    children =
      [{McpRegistry, name: mcp_registry_name}] ++
        Enum.map(
          servers,
          &child_spec_for(&1, capability_registry, mcp_registry_name, hermes_starter)
        )

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp child_spec_for(server, capability_registry, mcp_registry_name, hermes_starter) do
    server = resolve_server_env!(server)

    %{children: hermes_children, client_name: hermes_client} =
      hermes_starter.child_specs_for(server)

    server_spec =
      Supervisor.child_spec(
        {McpServer, server_opts(server, capability_registry, mcp_registry_name, hermes_client)},
        id: {:mcp_server, server.name},
        restart: :permanent
      )

    children = hermes_children ++ [server_spec]

    %{
      id: {:mcp_server_supervisor, server.name},
      start:
        {Supervisor, :start_link,
         [children, [strategy: :one_for_all, max_restarts: 3, max_seconds: 60]]},
      type: :supervisor,
      restart: :temporary
    }
  end

  defp server_opts(server, capability_registry, mcp_registry_name, hermes_client) do
    # Explicit `:client` in the server map (test-supplied) wins. Otherwise the
    # Hermes starter's spawned client name is the production default.
    client = Map.get(server, :client) || hermes_client

    [
      server_name: server.name,
      approved?: Map.get(server, :approved?, false),
      tools_overrides: Map.get(server, :tools_overrides, %{}),
      capability_registry: capability_registry,
      mcp_registry: mcp_registry_name
    ]
    |> maybe_put(:client, client)
    |> maybe_put(:discoverer, Map.get(server, :discoverer))
    |> maybe_put(:caller, Map.get(server, :caller))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp resolve_server_env!(server) do
    pass_env = Map.get(server, :pass_env, [])
    literal_env = Map.get(server, :env, %{})

    case SandboxEnv.build_command(SandboxConfig.current(), pass_env) do
      {:ok, sandbox_env} ->
        effective_env =
          sandbox_env
          |> Map.new()
          |> Map.merge(literal_env)

        Map.put(server, :env, effective_env)

      {:error, reason} ->
        raise ArgumentError,
              "MCP server #{server.name} env could not be built: #{SandboxEnv.format_error(reason)}"
    end
  end

  defp default_servers do
    Application.get_env(:fermix_core, :mcp_servers, [])
  end
end
