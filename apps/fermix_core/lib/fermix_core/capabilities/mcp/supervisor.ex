defmodule FermixCore.Capabilities.MCP.Supervisor do
  @moduledoc """
  Top-level MCP supervisor. Owns the per-server discovery + registration
  GenServers, the `MCP.Registry` client lookup table, and the
  `MCP.Naming` ETS table.

  The server list is `[mcp.servers.*]` TOML specs (`Application.get_env(
  :fermix_core, :mcp_servers, [])`) plus the plugin-owned specs
  `Plugins.Dist.McpSource` materializes from enabled `mcp`-rail plugins
  (M8 §8.2). A server config map (parsed by `MCP.Config` or built by
  `McpSource`) carries `name`, `command`, `args`, `env`, `pass_env`, and
  `tools_overrides`; plugin specs add `prefix`, `cwd`, and
  `capability_metadata`.

  Each per-server sub-supervisor contains the Anubis client child (built by
  the configured `:anubis_starter`, default `AnubisStarter.Default`) plus the
  `MCP.Server` discovery process. The two are linked under `:one_for_all`, so
  a transport crash bounces the client and the discovery process together.

  One bad server isolates inside its own subtree. The other servers keep
  running.

  `reload/2` diffs the running per-server children against the current
  desired list (TOML ++ plugin specs): new specs start, removed specs stop
  (disabling an `mcp` plugin stops its child process), and unchanged specs
  — identified by the child id `{:mcp_server_supervisor, name, spec_hash}`
  — are left running untouched.
  """

  use Supervisor
  require Logger

  alias FermixCore.Capabilities.MCP.AnubisStarter
  alias FermixCore.Capabilities.MCP.Naming
  alias FermixCore.Capabilities.MCP.Registry, as: McpRegistry
  alias FermixCore.Capabilities.MCP.Server, as: McpServer
  alias FermixCore.Plugins.Dist.McpSource
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Sandbox.Env, as: SandboxEnv

  @type opt ::
          {:name, atom()}
          | {:servers, [map()]}
          | {:capability_registry, GenServer.server()}
          | {:mcp_registry, GenServer.server() | nil}
          | {:anubis_starter, module()}

  @type reload_summary :: %{
          started: [String.t()],
          stopped: [String.t()],
          unchanged: [String.t()],
          failed: [String.t()]
        }

  @spec start_link([opt()]) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Naming.init()
    config = collaborators(opts)
    servers = Keyword.get_lazy(opts, :servers, &default_servers!/0)

    children =
      [{McpRegistry, name: config.mcp_registry}] ++
        Enum.map(servers, &child_spec_for(&1, config))

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Re-derive the desired server list and reconcile the running children
  against it: start specs that are not running, stop children whose spec is
  gone, leave unchanged specs alone (same name + same spec → same child id
  → the running child keeps its pid). Called from `Plugins.Runtime.reload/1`
  after a plugin/config change.

  Opts mirror `init/1`'s collaborator opts plus `:servers` to override the
  desired list (tests).
  """
  @spec reload() :: {:ok, reload_summary()} | {:error, term()}
  def reload, do: reload(__MODULE__, [])

  @spec reload(Supervisor.supervisor(), keyword()) ::
          {:ok, reload_summary()} | {:error, term()}
  def reload(supervisor, opts) when is_list(opts) do
    with {:ok, servers} <- desired_servers(opts) do
      {:ok, apply_server_diff(supervisor, servers, collaborators(opts))}
    end
  end

  defp collaborators(opts) do
    %{
      capability_registry:
        Keyword.get(opts, :capability_registry, FermixCore.Capabilities.Registry),
      mcp_registry: Keyword.get(opts, :mcp_registry, McpRegistry),
      anubis_starter: Keyword.get(opts, :anubis_starter, AnubisStarter.Default)
    }
  end

  defp desired_servers(opts) do
    case Keyword.fetch(opts, :servers) do
      {:ok, servers} ->
        {:ok, servers}

      :error ->
        with {:ok, plugin_specs} <- McpSource.server_specs() do
          {:ok, toml_servers() ++ plugin_specs}
        end
    end
  end

  defp apply_server_diff(supervisor, servers, config) do
    desired = Enum.map(servers, fn server -> {server_child_id(server), server} end)
    desired_ids = MapSet.new(desired, &elem(&1, 0))
    current_ids = current_server_ids(supervisor)

    stopped =
      current_ids
      |> Enum.reject(&MapSet.member?(desired_ids, &1))
      |> Enum.map(&stop_server(supervisor, &1))

    start_results =
      desired
      |> Enum.reject(fn {id, _server} -> id in current_ids end)
      |> Enum.map(fn {_id, server} -> start_server(supervisor, server, config) end)

    %{
      started: for({:ok, name} <- start_results, do: name),
      failed: for({:error, name} <- start_results, do: name),
      stopped: stopped,
      unchanged:
        current_ids |> Enum.filter(&MapSet.member?(desired_ids, &1)) |> Enum.map(&id_name/1)
    }
  end

  defp current_server_ids(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.flat_map(fn
      {{:mcp_server_supervisor, _name, _hash} = id, _pid, _type, _modules} -> [id]
      _other_child -> []
    end)
  end

  defp start_server(supervisor, server, config) do
    case Supervisor.start_child(supervisor, child_spec_for(server, config)) do
      {:ok, _pid} ->
        {:ok, server.name}

      {:error, reason} ->
        Logger.error("MCP server #{server.name} failed to start on reload: #{inspect(reason)}")
        {:error, server.name}
    end
  rescue
    # resolve_server_env! refuses bad env declarations loudly; on the reload
    # path one bad server must not abort the whole diff.
    error in ArgumentError ->
      Logger.error("MCP server #{server.name} rejected on reload: #{Exception.message(error)}")
      {:error, server.name}
  end

  # `:temporary` children drop their spec when they terminate, so the
  # delete is usually a no-op — kept for the not-yet-terminated case.
  defp stop_server(supervisor, id) do
    _ = Supervisor.terminate_child(supervisor, id)
    _ = Supervisor.delete_child(supervisor, id)
    id_name(id)
  end

  defp id_name({:mcp_server_supervisor, name, _hash}), do: name

  # Child identity = name + hash of the raw (pre-env-resolution) spec: an
  # unchanged spec maps to the same id and is never restarted; a changed
  # spec for the same name maps to a new id (old stops, new starts).
  defp server_child_id(server) do
    {:mcp_server_supervisor, server.name, :erlang.phash2(server)}
  end

  defp child_spec_for(server, config) do
    # The id hashes the raw spec — env resolution mixes in ambient sandbox
    # env and must not perturb child identity across reloads.
    id = server_child_id(server)
    server = resolve_server_env!(server)

    %{children: anubis_children, client_name: anubis_client} =
      config.anubis_starter.child_specs_for(server)

    server_spec =
      Supervisor.child_spec(
        {McpServer, server_opts(server, config, anubis_client)},
        id: {:mcp_server, server.name},
        restart: :permanent
      )

    children = anubis_children ++ [server_spec]

    %{
      id: id,
      start:
        {Supervisor, :start_link,
         [children, [strategy: :one_for_all, max_restarts: 3, max_seconds: 60]]},
      type: :supervisor,
      restart: :temporary
    }
  end

  defp server_opts(server, config, anubis_client) do
    # Explicit `:client` in the server map (test-supplied) wins. Otherwise the
    # Anubis starter's spawned client name is the production default.
    client = Map.get(server, :client) || anubis_client

    [
      server_name: server.name,
      tools_overrides: Map.get(server, :tools_overrides, %{}),
      capability_registry: config.capability_registry,
      mcp_registry: config.mcp_registry
    ]
    |> maybe_put(:client, client)
    |> maybe_put(:discoverer, Map.get(server, :discoverer))
    |> maybe_put(:caller, Map.get(server, :caller))
    |> maybe_put(:name_prefix, Map.get(server, :prefix))
    |> maybe_put(:extra_metadata, Map.get(server, :capability_metadata))
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

  defp toml_servers do
    Application.get_env(:fermix_core, :mcp_servers, [])
  end

  # Boot path: a registry that cannot even be read is a corrupt install —
  # fail loud at the boundary rather than booting with half the surface.
  defp default_servers! do
    case McpSource.server_specs() do
      {:ok, plugin_specs} ->
        toml_servers() ++ plugin_specs

      {:error, reason} ->
        raise ArgumentError,
              "MCP plugin server specs could not be built: #{inspect(reason)}"
    end
  end
end
