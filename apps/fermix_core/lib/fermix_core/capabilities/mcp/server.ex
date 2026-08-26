defmodule FermixCore.Capabilities.MCP.Server do
  @moduledoc """
  Per-server GenServer that owns the MCP tool registration lifecycle for
  one configured server.

  On init it discovers the server's tool list via the configured
  `Discoverer` (defaults to `Anubis` in production, swappable in tests),
  builds an `MCP.Capability` for each tool, and registers it with the
  capability registry. The client is published to `MCP.Registry` under the
  **source-qualified** identity so dispatch can resolve `{kind, name} -> pid`
  without two same-named servers reaching each other.

  On terminate it unregisters all of its capabilities (matched by
  `metadata.mcp_server`) and removes itself from the server registry.
  Discovery failures are logged and the GenServer exits — the parent
  supervisor decides the restart strategy.

  Completing registration is the point where the agent's view of the world
  changed, so it is the point that invalidates the cached one (M27 §7.8): the
  `MainAgent` runtime context and the realtime sessions are refreshed here, for
  **every** server, not only remote ones. A config reload invalidates before
  discovery has finished, so relying on that earlier invalidation would cache a
  pre-discovery tool list indefinitely.

  When the supervisor supplies a source-qualified identity and a
  `RuntimeStatus` sink, this process also writes the generation-qualified
  `:ready` and classified terminal statuses for that source. It pins its
  generation once, at init: if a replacement owner is installed mid-discovery,
  every write from this process is refused as stale rather than overwriting the
  replacement's status.

  ## Signed remote contract (M27 §7.6, §7.7)

  A remote spec compiles into a `Remote.Contract`, and registration becomes
  **transactional**: extras are discarded by raw name before any schema is
  bounded or hashed, every required descriptor must still match its signed
  `descriptor_sha256`, every final name is preflighted, and only then does
  anything register. One missing or changed descriptor registers **zero**
  capabilities. A registry race during the register phase rolls back every
  capability and every `MCP.Naming` reservation this attempt created, so a
  failed registration never leaves a partial tool set or a stale name.

  Local stdio servers keep their existing prefixing, per-tool tolerance, and
  discovery behaviour unchanged.
  """

  use GenServer
  require Logger

  alias FermixCore.Agents.MainAgent
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.MCP.Capability, as: McpCapability
  alias FermixCore.Capabilities.MCP.Naming
  alias FermixCore.Capabilities.MCP.Registry, as: McpRegistry
  alias FermixCore.Capabilities.MCP.Remote.Budget
  alias FermixCore.Capabilities.MCP.Remote.Contract
  alias FermixCore.Capabilities.MCP.Remote.Limits
  alias FermixCore.Capabilities.MCP.Remote.Owner, as: RemoteOwner
  alias FermixCore.Capabilities.MCP.Remote.Proxy
  alias FermixCore.Capabilities.MCP.RuntimeStatus
  alias FermixCore.Capabilities.MCP.Telemetry
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Realtime.SessionSupervisor

  @type opt ::
          {:server_name, String.t()}
          | {:source_id, RuntimeStatus.source_id() | nil}
          | {:client, term()}
          | {:discoverer, module()}
          | {:caller, module()}
          | {:approved?, boolean()}
          | {:tools_overrides, %{String.t() => map()}}
          | {:name_prefix, String.t() | nil}
          | {:extra_metadata, map() | nil}
          | {:contract, map() | nil}
          | {:budget, GenServer.server()}
          | {:rediscovery_interval_ms, non_neg_integer()}
          | {:proxy_dispatch, module()}
          | {:proxy_target, term()}
          | {:capability_registry, GenServer.server()}
          | {:mcp_registry, GenServer.server()}
          | {:runtime_status, GenServer.server() | nil}
          | {:main_agent, GenServer.server() | nil}
          | {:realtime_supervisor, GenServer.server() | nil}

  @spec start_link([opt()]) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Record a `notifications/tools/list_changed`.

  Suspends new calls immediately, then runs one bounded rediscovery pass.
  Notifications arriving during a pass coalesce into exactly one pending pass.
  """
  @spec tools_changed(GenServer.server()) :: :ok
  def tools_changed(server), do: GenServer.cast(server, :tools_changed)

  @impl true
  def init(opts) do
    # Supervisor shutdown (the plugin-disable reload path) delivers an exit
    # signal, not GenServer.stop/2 — terminate/2 only unregisters this
    # server's capabilities if exits are trapped.
    Process.flag(:trap_exit, true)

    state = build_state(opts)

    case compile_contract(state, Keyword.get(opts, :contract)) do
      {:ok, state} -> start_discovery(state)
      {:error, reason} -> {:ok, state, {:continue, {:refuse, reason}}}
    end
  end

  defp build_state(opts) do
    server_name = Keyword.fetch!(opts, :server_name)
    source_id = Keyword.get(opts, :source_id) || {:operator, server_name}

    state = %{
      server_name: server_name,
      source_id: source_id,
      runtime_status: Keyword.get(opts, :runtime_status),
      main_agent: Keyword.get(opts, :main_agent, MainAgent),
      realtime_supervisor: Keyword.get(opts, :realtime_supervisor, SessionSupervisor),
      generation: nil,
      client: Keyword.get(opts, :client),
      discoverer: Keyword.get(opts, :discoverer, FermixCore.Capabilities.MCP.Discoverer.Anubis),
      caller: Keyword.get(opts, :caller, FermixCore.Capabilities.MCP.Caller.Anubis),
      tools_overrides: Keyword.get(opts, :tools_overrides, %{}),
      name_prefix: Keyword.get(opts, :name_prefix),
      extra_metadata: Keyword.get(opts, :extra_metadata),
      capability_registry: Keyword.get(opts, :capability_registry, CapabilityRegistry),
      mcp_registry: Keyword.get(opts, :mcp_registry, McpRegistry),
      skill_registry: Keyword.get(opts, :skill_registry, SkillRegistry),
      contract: nil,
      proxy: nil,
      budget: Keyword.get(opts, :budget, Budget),
      proxy_dispatch: Keyword.get(opts, :proxy_dispatch, RemoteOwner),
      proxy_target: Keyword.get(opts, :proxy_target) || Keyword.get(opts, :client),
      registered_names: [],
      reserved_names: [],
      rediscoveries: 0,
      last_rediscovery_at: nil,
      rediscovery_interval_ms:
        Keyword.get(opts, :rediscovery_interval_ms, Limits.min_rediscovery_interval_ms()),
      rediscovering?: false,
      drift_pending?: false,
      discovery_attempts: 0,
      max_discovery_attempts: Keyword.get(opts, :max_discovery_attempts, 5),
      retry_base_ms: Keyword.get(opts, :retry_base_ms, 500),
      fail_fast?: Keyword.get(opts, :fail_fast?, false)
    }

    %{state | generation: pin_generation(state)}
  end

  # A remote source without a compilable signed contract is an invalid install,
  # not a server to start with weaker rules than the ones that were signed.
  defp compile_contract(state, nil), do: {:ok, state}

  defp compile_contract(state, spec) when is_map(spec) do
    with {:ok, contract} <- Contract.compile(spec),
         {:ok, proxy} <- start_proxy(state, contract) do
      :ok = McpRegistry.register_proxy(state.mcp_registry, state.source_id, proxy)
      {:ok, %{state | contract: contract, proxy: proxy}}
    else
      {:error, reason} ->
        _ = record_terminal(state, reason)
        {:error, reason}
    end
  end

  defp start_proxy(state, contract) do
    Proxy.start_link(
      contract: contract,
      dispatch: state.proxy_dispatch,
      target: state.proxy_target,
      budget: state.budget,
      notify: self()
    )
  end

  defp start_discovery(state) do
    if state.fail_fast? do
      case discover_and_register(state) do
        {:ok, state} -> {:ok, state}
        {:error, reason} -> {:stop, {:mcp_discovery_failed, state.server_name, reason}}
      end
    else
      {:ok, state, {:continue, :discover}}
    end
  end

  # A signed contract that will not compile is terminal for THIS source, not for
  # the daemon. Returning `{:stop, reason}` from `init/1` fails the child start,
  # and that cascades: sub-supervisor -> MCP.Supervisor -> application boot. One
  # plugin whose upstream drifted would take every other plugin, and the whole
  # daemon, down with it. So start, record the terminal status, and stop
  # `:normal` — `restart: :transient` + `significant: true` +
  # `auto_shutdown: :any_significant` then tear down just this subtree, and the
  # operator sees the reason in setup and `fermix doctor`.
  def handle_continue({:refuse, reason}, state) do
    {:stop, :normal, record_terminal(state, reason)}
  end

  @impl true
  def handle_continue(:discover, state) do
    case discover_and_register(state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason} ->
        handle_discovery_failure(reason, state)
    end
  end

  @impl true
  def handle_cast(:tools_changed, state), do: drift(state)

  @impl true
  def handle_info(:retry_discovery, state) do
    {:noreply, state, {:continue, :discover}}
  end

  def handle_info(:rediscover, state), do: rediscover(state)

  # The proxy saw the bounded run of invalid results. Capabilities come down and
  # the session is terminal; only an explicit reconnect brings it back.
  def handle_info({:mcp_proxy, :protocol_error, class}, state) do
    state = unregister_all(state)
    {:stop, :normal, record_terminal(state, {:remote_protocol_error, class})}
  end

  def handle_info({:EXIT, proxy, reason}, %{proxy: proxy} = state) when is_pid(proxy) do
    state = unregister_all(%{state | proxy: nil})
    {:stop, :normal, record_terminal(state, reason)}
  end

  # A stray message must not kill a registration the operator depends on, and its
  # payload is never logged: a term arriving here could carry anything.
  def handle_info(message, state) do
    Logger.debug("MCP server #{state.server_name} ignored #{inspect(message_kind(message))}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    _ = unregister_all(state)

    if is_pid(state.client) or is_pid(state.proxy) do
      best_effort_unregister(fn ->
        McpRegistry.unregister(state.mcp_registry, state.source_id)
      end)
    end

    # The deregistration counterpart of the registration hook: tools the agent
    # can still see in its cached context but can no longer call are exactly
    # the staleness this closes. Skipped when this server never registered
    # anything, and a no-op during app shutdown (the MainAgent stops first).
    if state.registered_names != [], do: refresh_runtime_context(state)

    :ok
  end

  # terminate/2 runs during shutdown, where the capability/MCP registries may be
  # concurrently terminating — their unregister `GenServer.call` then exits
  # `:noproc` (or a shutdown reason) and would crash this callback, leaving the
  # capability half-cleaned and leaking into later work. A dead registry holds no
  # capabilities, so the unregister postcondition is already satisfied: swallow
  # only the registry-is-gone exits and let any real fault (e.g. a `:timeout`
  # from a live-but-stuck registry) propagate.
  defp best_effort_unregister(fun) do
    _ = fun.()
    :ok
  catch
    :exit, {reason, {GenServer, :call, _}} when reason in [:noproc, :normal, :shutdown] ->
      Logger.debug(
        "MCP server terminate: registry already gone (#{inspect(reason)}); skipping unregister"
      )

      :ok
  end

  defp discover_and_register(state) do
    with :ok <- maybe_register_client(state),
         {:ok, descriptors} <- list_tools(state),
         {:ok, state} <- register_tools(descriptors, state) do
      {:ok, complete_registration(%{state | discovery_attempts: 0})}
    end
  end

  defp register_tools(descriptors, %{contract: nil} = state) do
    registered = Enum.flat_map(descriptors, &register_descriptor(&1, state))
    {:ok, %{state | registered_names: registered}}
  end

  defp register_tools(descriptors, state), do: register_contract(descriptors, state)

  defp list_tools(state) do
    started = System.monotonic_time(:millisecond)
    result = state.discoverer.list_tools(state.client)

    emit_lifecycle(
      state,
      :discover,
      result,
      System.monotonic_time(:millisecond) - started,
      state.discovery_attempts + 1
    )

    result
  end

  # The shared registration-completion point: the agent's tool list is only now
  # what the registry says it is.
  defp complete_registration(state) do
    _ = put_status(state, :ready, nil, nil)
    emit_lifecycle(state, :ready, :ok, 0, 1)
    if state.proxy, do: Proxy.resume(state.proxy, state.contract)
    refresh_runtime_context(state)
    state
  end

  defp handle_discovery_failure(reason, state) do
    attempts = state.discovery_attempts + 1
    state = %{state | discovery_attempts: attempts}

    if attempts >= state.max_discovery_attempts or terminal_contract_error?(reason) do
      Logger.error(
        "MCP server #{state.server_name} discovery failed #{attempts} times, giving up: " <>
          inspect(error_class(reason))
      )

      {:stop, :normal, record_terminal(state, reason)}
    else
      delay = state.retry_base_ms * round(:math.pow(2, attempts - 1))
      log_retry(reason, state.server_name, attempts, state.max_discovery_attempts, delay)
      Process.send_after(self(), :retry_discovery, delay)
      {:noreply, state}
    end
  end

  # A contract mismatch or a name collision cannot become success by repetition:
  # the same signed hashes will disagree with the same live descriptors next
  # time. Retrying it only delays the operator's visible terminal status.
  defp terminal_contract_error?({:upstream_contract_mismatch, _detail}), do: true
  defp terminal_contract_error?({:capability_conflict, _detail}), do: true
  defp terminal_contract_error?(_reason), do: false

  # `Server capabilities not set` is the expected response while the MCP
  # client is still racing through `initialize` — log at debug, not warning,
  # so a noisy `npx`-backed startup doesn't surface as a red flag to the
  # operator. Real errors (transport closed, unexpected response shape,
  # tool schema errors) keep the warning level.
  defp log_retry(reason, server_name, attempts, max_attempts, delay) do
    message =
      "MCP server #{server_name} discovery failed (attempt #{attempts}/#{max_attempts}); " <>
        "retrying in #{delay}ms: #{inspect(error_class(reason))}"

    if expected_startup_error?(reason),
      do: Logger.debug(message),
      else: Logger.warning(message)
  end

  defp expected_startup_error?(%Anubis.MCP.Error{reason: :internal_error, data: %{message: msg}})
       when is_binary(msg) do
    String.contains?(msg, "Server capabilities not set")
  end

  defp expected_startup_error?(_reason), do: false

  defp maybe_register_client(%{client: nil}), do: :ok

  # A remote source's raw client is never published: only its allowlisted proxy
  # is, and that already happened at init.
  defp maybe_register_client(%{contract: contract}) when not is_nil(contract), do: :ok

  defp maybe_register_client(%{client: client} = state) when is_pid(client) do
    McpRegistry.register(state.mcp_registry, state.source_id, client)
  end

  defp maybe_register_client(%{client: client} = state) when is_atom(client) do
    case Process.whereis(client) do
      pid when is_pid(pid) ->
        McpRegistry.register(state.mcp_registry, state.source_id, pid)

      nil ->
        {:error, {:anubis_client_not_started, client}}
    end
  end

  defp maybe_register_client(_state), do: :ok

  # --- stdio registration (unchanged) ------------------------------------

  defp register_descriptor(descriptor, state) do
    overrides = Map.get(state.tools_overrides, descriptor.name, %{})
    original = descriptor.name
    sanitized = Naming.candidate(state.server_name, original, prefix: state.name_prefix)

    with :ok <- reject_skill_name_collision(sanitized, state, original) do
      capability =
        McpCapability.from_tool_descriptor(state.server_name, descriptor,
          source_id: state.source_id,
          caller: state.caller,
          tool_overrides: overrides,
          name_prefix: state.name_prefix,
          extra_metadata: state.extra_metadata
        )

      case CapabilityRegistry.register(state.capability_registry, capability) do
        :ok ->
          [capability.name]

        {:error, {:duplicate_name, _}} ->
          Logger.warning(
            "MCP duplicate capability name during registration: #{capability.name} " <>
              "(server=#{state.server_name}, tool=#{descriptor.name})"
          )

          []
      end
    else
      {:error, {:skill_name_collision, name}} ->
        Logger.warning(
          "MCP tool #{state.server_name}/#{original} sanitized to #{name}, " <>
            "which collides with an installed skill. Rename the MCP tool or skill."
        )

        []
    end
  end

  # --- transactional signed registration (§7.7) --------------------------

  defp register_contract(descriptors, state) do
    with {:ok, selected} <- Contract.select(state.contract, descriptors),
         {:ok, verified} <- Contract.verify(state.contract, selected),
         :ok <- preflight(verified, state),
         {:ok, names} <- register_all(verified, state) do
      {:ok, %{state | registered_names: names, reserved_names: names}}
    end
  end

  # Every final name is checked BEFORE anything registers, so the common failure
  # (a collision the operator can see coming) never has to be rolled back.
  defp preflight(verified, state) do
    names = Enum.map(verified, & &1.final_name)

    with :ok <- refuse_duplicate_names(names) do
      refuse_skill_collision(names, skill_names(state.skill_registry))
    end
  end

  defp refuse_duplicate_names(names) do
    case names -- Enum.uniq(names) do
      [] -> :ok
      [name | _rest] -> {:error, {:capability_conflict, {:duplicate_name, name}}}
    end
  end

  defp refuse_skill_collision(names, skills) do
    case Enum.find(names, &(&1 in skills)) do
      nil -> :ok
      name -> {:error, {:capability_conflict, {:skill_name_collision, name}}}
    end
  end

  defp register_all(verified, state) do
    Enum.reduce_while(verified, {:ok, []}, fn tool, {:ok, names} ->
      case register_one(tool, state) do
        {:ok, name} ->
          {:cont, {:ok, [name | names]}}

        {:error, reason} ->
          rollback(names, state)
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, names} -> {:ok, Enum.reverse(names)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Owns its own partial work: a reservation whose capability registration then
  # failed is released HERE, so the rollback list never has to know about a
  # name that was reserved but never registered.
  defp register_one(tool, state) do
    with {:ok, name} <- Naming.reserve(state.server_name, tool.name, tool.final_name) do
      settle_registration(tool, name, state)
    end
  end

  defp settle_registration(tool, name, state) do
    case register_capability(tool, name, state) do
      :ok ->
        {:ok, name}

      {:error, reason} ->
        Naming.unregister(name)
        {:error, reason}
    end
  end

  defp register_capability(tool, name, state) do
    capability =
      McpCapability.from_tool_descriptor(
        state.server_name,
        %{name: tool.name, description: tool.description, input_schema: tool.parameters},
        source_id: state.source_id,
        caller: state.caller,
        final_name: name,
        parameters: tool.parameters,
        policy: policy_handle(state.contract, tool.policy),
        tool_overrides: Map.get(state.tools_overrides, tool.name, %{}),
        extra_metadata: state.extra_metadata
      )

    case CapabilityRegistry.register(state.capability_registry, capability) do
      :ok -> :ok
      {:error, {:duplicate_name, _}} -> {:error, {:capability_conflict, {:duplicate_name, name}}}
    end
  end

  # The compiled policy handle that follows the invocation path — signed facts
  # only, no raw manifest data.
  defp policy_handle(contract, policy) do
    %{
      profile: contract.selected_profile,
      read_only: policy.read_only,
      replay_safe: policy.replay_safe,
      credential_scope: policy.credential_scope,
      resource_scope_kind: contract.resource_scope.kind
    }
  end

  # A registry race is the only way to get here, and it must leave nothing
  # behind: every capability AND every naming reservation this attempt created
  # is removed before the failure is recorded.
  defp rollback(names, state) do
    Enum.each(names, &CapabilityRegistry.unregister(state.capability_registry, &1))
    Enum.each(names, &Naming.unregister/1)
    :ok
  end

  defp unregister_all(state) do
    Enum.each(state.registered_names, fn name ->
      best_effort_unregister(fn ->
        CapabilityRegistry.unregister(state.capability_registry, name)
      end)
    end)

    Enum.each(state.reserved_names, &Naming.unregister/1)
    %{state | registered_names: [], reserved_names: []}
  end

  # --- drift (§7.6) ------------------------------------------------------

  # Suspend FIRST: the old contract must never be served after a drift
  # notification, including during the pacing wait before the pass starts.
  defp drift(%{contract: nil} = state), do: {:noreply, state}

  defp drift(%{rediscovering?: true} = state),
    do: {:noreply, %{state | drift_pending?: true}}

  defp drift(state) do
    if state.proxy, do: Proxy.suspend(state.proxy)
    emit_lifecycle(state, :drift, :ok, 0, state.rediscoveries + 1)
    state = unregister_all(%{state | rediscovering?: true, drift_pending?: false})

    if state.rediscoveries >= Limits.max_rediscoveries_per_session() do
      {:stop, :normal, record_terminal(state, {:upstream_contract_mismatch, :rediscovery_cap})}
    else
      Process.send_after(self(), :rediscover, rediscovery_wait(state))
      {:noreply, state}
    end
  end

  defp rediscovery_wait(%{last_rediscovery_at: nil}), do: 0

  defp rediscovery_wait(state) do
    elapsed = System.monotonic_time(:millisecond) - state.last_rediscovery_at
    max(state.rediscovery_interval_ms - elapsed, 0)
  end

  defp rediscover(state) do
    state = %{
      state
      | rediscoveries: state.rediscoveries + 1,
        last_rediscovery_at: System.monotonic_time(:millisecond)
    }

    case discover_and_register(state) do
      {:ok, state} -> settle_rediscovery(state)
      {:error, reason} -> {:stop, :normal, record_terminal(state, reason)}
    end
  end

  # Notifications received during the pass collapse into exactly one follow-up.
  defp settle_rediscovery(%{drift_pending?: true} = state),
    do: drift(%{state | rediscovering?: false})

  defp settle_rediscovery(state), do: {:noreply, %{state | rediscovering?: false}}

  # --- runtime status, telemetry, and the shared refresh -----------------

  # The generation is pinned ONCE. Re-reading it per write would let a
  # replacement's generation authorize this process's late status.
  defp pin_generation(%{source_id: nil}), do: nil
  defp pin_generation(%{runtime_status: nil}), do: nil

  defp pin_generation(state) do
    if alive?(state.runtime_status),
      do: current_generation(state),
      else: nil
  end

  defp current_generation(state) do
    case RuntimeStatus.owner(state.runtime_status, state.source_id) do
      {:ok, _owner, generation} -> generation
      # No owner: a stdio server has none, so it has no live status to write.
      :error -> nil
    end
  end

  defp record_terminal(state, reason) do
    {status, detail} = RuntimeStatus.classify(reason)

    case put_status(state, status, detail, RuntimeStatus.capability_from(reason)) do
      :ok -> refresh_runtime_context(state)
      _no_write -> :ok
    end

    state
  end

  defp put_status(%{generation: nil}, _status, _detail, _capability), do: :no_status_sink

  defp put_status(state, status, detail, capability) do
    case RuntimeStatus.put(
           state.runtime_status,
           state.source_id,
           state.generation,
           status,
           detail,
           capability
         ) do
      :ok -> :ok
      # A replaced owner's discovery must never overwrite its replacement.
      {:error, :stale_generation} -> :stale_generation
    end
  end

  defp emit_lifecycle(%{source_id: nil}, _phase, _result, _duration_ms, _attempt), do: :ok

  defp emit_lifecycle(state, phase, result, duration_ms, attempt) do
    Telemetry.emit_lifecycle(
      phase,
      %{source_id: state.source_id, plugin: plugin_of(state)},
      result,
      max(duration_ms, 0),
      attempt: attempt
    )
  end

  defp plugin_of(%{extra_metadata: %{plugin: plugin}}) when is_binary(plugin), do: plugin
  defp plugin_of(_state), do: nil

  # Drop the agent's cached view and let the realtime sessions pick the new
  # tool list up. Both are no-ops before their owners exist (boot starts the
  # MCP tree first) — a precondition, not a degraded path.
  defp refresh_runtime_context(state) do
    invalidate_main_agent(state.main_agent)
    reload_realtime(state.realtime_supervisor)
  end

  defp invalidate_main_agent(server) do
    if alive?(server),
      do: MainAgent.invalidate_runtime_context(server, :plugins_changed),
      else: :ok
  end

  defp reload_realtime(server) do
    if alive?(server), do: SessionSupervisor.reload_sessions(server), else: {:ok, :skipped}
  end

  defp alive?(nil), do: false
  defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp alive?(name) when is_atom(name), do: Process.whereis(name) != nil

  defp reject_skill_name_collision(name, state, _original) do
    if name in skill_names(state.skill_registry) do
      {:error, {:skill_name_collision, name}}
    else
      :ok
    end
  end

  defp skill_names(nil), do: []

  defp skill_names(server) when is_atom(server) do
    case Process.whereis(server) do
      nil ->
        Logger.debug(
          "MCP skill-name collision check skipped; skill registry #{server} is not running"
        )

        []

      _pid ->
        safe_skill_names(server)
    end
  end

  defp skill_names(server), do: safe_skill_names(server)

  defp safe_skill_names(server) do
    SkillRegistry.list(server)
  catch
    :exit, reason ->
      Logger.debug("MCP skill-name collision check failed: #{inspect(reason)}")
      []
  end

  # A remote reason can embed an endpoint, a schema, or a peer message. Only the
  # atom class reaches a log line; the reason itself still rides the classified
  # `RuntimeStatus` entry the operator reads.
  defp error_class(reason) when is_atom(reason), do: reason
  defp error_class(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0)
  defp error_class(_reason), do: :unclassified

  defp message_kind(message) when is_tuple(message) and tuple_size(message) > 0,
    do: elem(message, 0)

  defp message_kind(message) when is_atom(message), do: message
  defp message_kind(_message), do: :unknown
end
