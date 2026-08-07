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
  — identified by the child id `{:mcp_server_supervisor, source_id, spec_hash}`
  — are left running untouched.

  Child identity is **source-qualified** (M27 §7.3): `{:plugin, "eden"}` for a
  plugin-owned server, `{:operator, "eden"}` for a `[mcp.servers.eden]` TOML
  one. Two servers may share a name; they can never share an identity, so
  stopping the plugin client can never stop the operator's.

  `reload/2` is a best-effort fan-out whose child identity hashes the
  *non-secret* spec, so it cannot observe a credential change. Credential
  rotation, disable, and forget use `stop_server/2` and `restart_server/4`
  instead: they are synchronous, source-qualified, and prove process death.
  """

  use Supervisor
  require Logger

  alias FermixCore.Capabilities.MCP.AnubisStarter
  alias FermixCore.Capabilities.MCP.Caller.Remote, as: RemoteCaller
  alias FermixCore.Capabilities.MCP.Naming
  alias FermixCore.Capabilities.MCP.Registry, as: McpRegistry
  alias FermixCore.Capabilities.MCP.Remote.Budget
  alias FermixCore.Capabilities.MCP.Remote.Owner, as: RemoteOwner
  alias FermixCore.Capabilities.MCP.RuntimeStatus
  alias FermixCore.Capabilities.MCP.Server, as: McpServer
  alias FermixCore.Plugins.Dist.McpSource
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Sandbox.Env, as: SandboxEnv

  # A stop first asks the owner for an orderly protocol teardown, then uses the
  # supervisor's termination path, then requires proof of death. The three
  # budgets sum to the 15-second total deadline (§7.5).
  @teardown_ms 10_000
  @kill_grace_ms 5_000

  @type source_id :: {atom(), String.t()}

  @type opt ::
          {:name, atom()}
          | {:servers, [map()]}
          | {:capability_registry, GenServer.server()}
          | {:mcp_registry, GenServer.server() | nil}
          | {:runtime_status, GenServer.server() | nil}
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
      [{McpRegistry, name: config.mcp_registry}, {Budget, name: config.budget}] ++
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

  @doc """
  Stop one source-qualified server and **prove** it stopped.

  The owner is asked for an orderly protocol teardown first (at most
  #{@teardown_ms}ms), then the supervisor's termination path runs, then `:DOWN`
  must arrive within the #{@kill_grace_ms}ms kill grace. Anything else is an
  error: a credential rotation that commits a new PAT while the old in-memory
  bearer is still alive somewhere is exactly the failure this refuses to
  report as success.
  """
  @spec stop_server(source_id()) :: :ok | {:error, term()}
  def stop_server(source_id), do: stop_server(__MODULE__, source_id, [])

  @spec stop_server(Supervisor.supervisor(), source_id(), keyword()) :: :ok | {:error, term()}
  def stop_server(supervisor, {kind, name} = source_id, opts \\ [])
      when is_atom(kind) and is_binary(name) and is_list(opts) do
    case find_child(supervisor, source_id) do
      # Nothing running for this source: there is no client left holding a
      # credential, which is precisely what the caller needed proven.
      :error -> :ok
      {:ok, id, pid} -> quiesce(supervisor, source_id, id, pid, opts)
    end
  end

  @doc """
  Stop a source-qualified server, prove it stopped, then start `spec` in its
  place. The old client is never left running: a start failure is reported
  with the source already stopped.
  """
  @spec restart_server(source_id(), map()) :: {:ok, pid()} | {:error, term()}
  def restart_server(source_id, spec), do: restart_server(__MODULE__, source_id, spec, [])

  @spec restart_server(Supervisor.supervisor(), source_id(), map(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def restart_server(supervisor, {kind, name} = source_id, spec, opts)
      when is_atom(kind) and is_binary(name) and is_map(spec) and is_list(opts) do
    with :ok <- stop_server(supervisor, source_id, opts) do
      Supervisor.start_child(supervisor, child_spec_for(spec, collaborators(opts)))
    end
  end

  defp collaborators(opts) do
    mcp_registry = Keyword.get(opts, :mcp_registry, McpRegistry)

    %{
      capability_registry:
        Keyword.get(opts, :capability_registry, FermixCore.Capabilities.Registry),
      mcp_registry: mcp_registry,
      runtime_status: Keyword.get(opts, :runtime_status, RuntimeStatus),
      budget: Keyword.get(opts, :budget, budget_name(mcp_registry)),
      anubis_starter: Keyword.get(opts, :anubis_starter, AnubisStarter.Default)
    }
  end

  # One remote-call budget per MCP tree, named after that tree's registry: two
  # supervisors (production and a test's) must not fight over one registered
  # name, and a budget shared across trees would let one tree's turn spend
  # another's ceiling.
  defp budget_name(registry) when is_atom(registry), do: :"#{registry}.Budget"

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
      |> Enum.map(&stop_child(supervisor, &1))

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
      {{:mcp_server_supervisor, _source_id, _hash} = id, _pid, _type, _modules} -> [id]
      _other_child -> []
    end)
  end

  defp find_child(supervisor, source_id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(:error, fn
      {{:mcp_server_supervisor, ^source_id, _hash} = id, pid, _type, _modules} when is_pid(pid) ->
        {:ok, id, pid}

      _other_child ->
        nil
    end)
  end

  # Monitor BEFORE anything else: the proof of death has to be armed before the
  # thing that causes it. Every step then runs against one absolute deadline, so
  # a wedged owner cannot spend the budget the termination path still needs.
  defp quiesce(supervisor, source_id, id, pid, opts) do
    deadline = System.monotonic_time(:millisecond) + @teardown_ms + @kill_grace_ms
    ref = Process.monitor(pid)

    _ = bounded(fn -> teardown_owner(source_id, opts) end, @teardown_ms)
    _ = bounded(fn -> Supervisor.terminate_child(supervisor, id) end, remaining(deadline))
    _ = Supervisor.delete_child(supervisor, id)

    await_down(ref, source_id, min(@kill_grace_ms, remaining(deadline)))
  end

  defp teardown_owner(source_id, opts) do
    case owner_pid(source_id, opts) do
      {:ok, owner} -> RemoteOwner.teardown(owner)
      :error -> :ok
    end
  end

  # Only a remote source has an owner registered in `RuntimeStatus`; a stdio
  # subtree has nothing to say goodbye with.
  defp owner_pid(source_id, opts) do
    status_server = Keyword.get(opts, :runtime_status, RuntimeStatus)

    if alive?(status_server) do
      with {:ok, owner, _generation} <- RuntimeStatus.owner(status_server, source_id),
           do: {:ok, owner}
    else
      :error
    end
  end

  # Unlinked on purpose: a step that crashes or hangs — a wedged owner, a
  # subtree that ignores its shutdown — must not take down the caller that is
  # trying to stop it. The step's return value is not the proof of anything;
  # the monitor is.
  defp bounded(fun, budget_ms) do
    {pid, ref} = spawn_monitor(fun)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      budget_ms ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
        :timeout
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 1)

  # Death is proven by the monitor, never inferred from `terminate_child`
  # returning: a subtree that ignored its shutdown is exactly the case the
  # caller must not treat as stopped.
  defp await_down(ref, source_id, grace_ms) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      grace_ms ->
        Process.demonitor(ref, [:flush])
        {:error, {:stop_not_proven, source_id}}
    end
  end

  defp alive?(nil), do: false
  defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp alive?(name) when is_atom(name), do: Process.whereis(name) != nil

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
  # delete is usually a no-op — kept for the not-yet-terminated case. This is
  # the reload diff's best-effort stop; `stop_server/3` is the one that proves
  # death.
  defp stop_child(supervisor, id) do
    _ = Supervisor.terminate_child(supervisor, id)
    _ = Supervisor.delete_child(supervisor, id)
    id_name(id)
  end

  defp id_name({:mcp_server_supervisor, {_kind, name}, _hash}), do: name

  # Child identity = source-qualified id + hash of the raw (pre-env-resolution)
  # spec: an unchanged spec maps to the same id and is never restarted; a
  # changed spec for the same source maps to a new id (old stops, new starts).
  #
  # The hash covers the non-secret spec only — the `auth_ref` is opaque, so a
  # rotated credential does NOT change this id. That is why rotation must go
  # through `stop_server/3`, never `reload/2`.
  defp server_child_id(server) do
    {:mcp_server_supervisor, source_id(server), :erlang.phash2(server)}
  end

  # A spec that names no source came from the operator rail: `[mcp.servers.*]`
  # TOML has no source field by construction, while every plugin-owned spec
  # `McpSource` builds carries `{:plugin, name}`.
  defp source_id(%{source_id: {kind, name}}) when is_atom(kind) and is_binary(name),
    do: {kind, name}

  defp source_id(%{name: name}) when is_binary(name), do: {:operator, name}

  defp child_spec_for(server, config) do
    # The id hashes the raw spec — env resolution mixes in ambient sandbox
    # env and must not perturb child identity across reloads.
    id = server_child_id(server)
    server = resolve_server_env!(server)

    %{children: anubis_children, client_name: anubis_client} =
      config.anubis_starter.child_specs_for(server, config)

    # `:transient` + `significant: true` (paired with the sub-supervisor's
    # `auto_shutdown: :any_significant`) makes the server's own give-up terminal:
    # after exhausting discovery retries it exits `:normal`, which a transient
    # child is not restarted from, and the auto_shutdown tears the whole subtree
    # (Anubis client included) down instead of respawning it forever. A genuine
    # abnormal crash (transport blip) is still restarted — transient recovers on
    # abnormal exits, and one_for_all re-runs discovery when the client bounces.
    server_spec =
      Supervisor.child_spec(
        {McpServer, server_opts(server, config, anubis_client)},
        id: {:mcp_server, server.name},
        restart: :transient,
        significant: true
      )

    children = anubis_children ++ [server_spec]

    %{
      id: id,
      start:
        {Supervisor, :start_link,
         [
           children,
           [
             strategy: :one_for_all,
             max_restarts: 3,
             max_seconds: 60,
             auto_shutdown: :any_significant
           ]
         ]},
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
      source_id: source_id(server),
      tools_overrides: Map.get(server, :tools_overrides, %{}),
      capability_registry: config.capability_registry,
      mcp_registry: config.mcp_registry,
      runtime_status: config.runtime_status,
      budget: config.budget
    ]
    |> maybe_put(:client, client)
    |> maybe_put(:discoverer, discoverer_for(server))
    |> maybe_put(:caller, caller_for(server))
    |> maybe_put(:contract, contract_for(server))
    |> maybe_put(:name_prefix, Map.get(server, :prefix))
    |> maybe_put(:extra_metadata, Map.get(server, :capability_metadata))
    |> maybe_put(:max_discovery_attempts, Map.get(server, :max_discovery_attempts))
    |> maybe_put(:retry_base_ms, Map.get(server, :retry_base_ms))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # A remote server's tool list comes from its own connection owner, over the
  # session that owner already authenticated — there is no Anubis client to ask.
  defp discoverer_for(%{discoverer: discoverer}), do: discoverer
  defp discoverer_for(%{transport: :streamable_http}), do: RemoteOwner
  defp discoverer_for(_server), do: nil

  # A remote source dispatches through its allowlisted proxy, never a raw client
  # (M27 §7.6). The signed spec itself is the contract enforcer's input.
  defp caller_for(%{caller: caller}), do: caller
  defp caller_for(%{transport: :streamable_http}), do: RemoteCaller
  defp caller_for(_server), do: nil

  defp contract_for(%{transport: :streamable_http} = server), do: server
  defp contract_for(_server), do: nil

  # A remote spec describes an HTTPS endpoint, not a process: it has no
  # environment to build, and `env`/`pass_env` on one would be a
  # half-local/half-remote spec (§7.3). Refuse it loudly rather than resolving
  # an environment nothing will ever read.
  defp resolve_server_env!(%{transport: :streamable_http} = server) do
    leaked = Enum.filter([:env, :pass_env], &Map.has_key?(server, &1))

    if leaked == [],
      do: server,
      else:
        raise(
          ArgumentError,
          "remote MCP server #{server.name} must not declare #{inspect(leaked)}"
        )
  end

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
