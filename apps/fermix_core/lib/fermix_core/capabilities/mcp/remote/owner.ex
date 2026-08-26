defmodule FermixCore.Capabilities.MCP.Remote.Owner do
  @moduledoc """
  Owns one remote MCP client for one source-qualified identity (M27 §6, §7.3).

  The owner is the only process that holds the live `Remote.Session`, and it
  closes it on every exit path — orderly teardown first, then the local socket.
  The credential itself is never here: the supervisor child spec carries the
  opaque `auth_ref`, and the session resolves it inside its own `init/1`, so a
  `failed_to_start_child` report or a crash dump cannot print a bearer token.
  Start errors and refusals log `redacted/1`, never the spec.

  Connecting happens in `handle_continue/2`, not `init/1`. A remote endpoint
  that is merely unreachable would otherwise hold the whole MCP supervisor's
  synchronous start for the full 60-second startup budget, and daemon boot with
  it. Discovery calls that arrive before the session exists are answered
  `{:error, :remote_not_connected}`; `MCP.Server`'s existing bounded retry is
  the same mechanism that already covers the stdio "client still initializing"
  race, so there is one waiting rule, not two.

  Startup is capped at `Limits.max_startup_attempts/0` inside the startup
  deadline, and only *unreachability* is retried. Authentication, endpoint
  policy, protocol, and contract failures stop immediately with a classified
  terminal status: retrying a rejected PAT cannot succeed, and repeating it is
  how an account gets locked.

  Giving up exits `:normal`. As a `:transient`, `significant: true` child that
  is terminal for the subtree (`auto_shutdown: :any_significant`), so the
  client is not respawned forever behind an operator's back — the visible
  terminal `RuntimeStatus` entry outlives the subtree and explains why.
  """

  use GenServer

  require Logger

  alias FermixCore.Capabilities.MCP.Discoverer
  alias FermixCore.Capabilities.MCP.Remote.AuthRef
  alias FermixCore.Capabilities.MCP.Remote.Endpoint
  alias FermixCore.Capabilities.MCP.Remote.Limits
  alias FermixCore.Capabilities.MCP.Remote.Session
  alias FermixCore.Capabilities.MCP.RuntimeStatus
  alias FermixCore.Capabilities.MCP.Telemetry
  alias FermixCore.Timeouts

  @behaviour Discoverer

  # Between bounded startup attempts. Not a config knob: the whole retry budget
  # (3 attempts) must stay far inside the 60-second startup deadline that
  # `Connect` is simultaneously waiting on.
  @retry_backoff_ms 500

  @type opt ::
          {:spec, map()}
          | {:runtime_status, GenServer.server() | nil}
          | {:name, GenServer.name()}
          # Seams, forwarded verbatim to `Remote.Session`: the module itself,
          # its transport module, its connect opts, and its credential resolver.
          | {:session, module()}
          | {:transport, module()}
          | {:connect_opts, keyword()}
          | {:resolver, (String.t() -> String.t() | nil)}
          | {:client_info, map()}

  @doc "The registered name for a source-qualified owner."
  @spec name_for(RuntimeStatus.source_id()) :: atom()
  def name_for({kind, name}) when is_atom(kind) and is_binary(name) do
    :"#{__MODULE__}.#{kind}.#{name}"
  end

  @spec start_link([opt()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    if name,
      do: GenServer.start_link(__MODULE__, opts, name: name),
      else: GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  The configuration view that is safe to log.

  It answers "which endpoint, which profile, which identity" and nothing that
  identifies a resource or a credential: the workspace id is an opaque handle
  to the operator's own data and has no place in a log line (§11.1).
  """
  @spec redacted(map()) :: map()
  def redacted(spec) when is_map(spec) do
    %{
      source_id: Map.get(spec, :source_id),
      transport: Map.get(spec, :transport),
      protocol_version: Map.get(spec, :protocol_version),
      base_url: Map.get(spec, :base_url),
      mcp_path: Map.get(spec, :mcp_path),
      name_mode: Map.get(spec, :name_mode),
      selected_profile: Map.get(spec, :selected_profile),
      resource_scope_kind: spec |> Map.get(:resource_scope, %{}) |> Map.get(:kind)
    }
  end

  @doc """
  Discoverer callback: the remote server's complete, bounded tool list.

  The call budget is the whole startup deadline because the owner may still be
  connecting; timing out here and retrying would start a second connect race
  against the first.
  """
  @impl Discoverer
  def list_tools(owner) do
    GenServer.call(owner, :list_tools, Timeouts.mcp_remote_startup() + 5_000)
  catch
    # The owner refused and is tearing its subtree down. Discovery reports that
    # as an error instead of dying with a raw `:noproc` — the classified status
    # the owner already wrote is the explanation, not this exit.
    :exit, {reason, {GenServer, :call, _args}} when reason in [:noproc, :normal, :shutdown] ->
      {:error, :remote_owner_down}
  end

  @doc """
  Issue one allowlisted `tools/call` on the owned session.

  This is the dispatch target `Remote.Proxy` calls once a request has passed
  every gate — profile membership, resource scope, budgets, argument guards.
  The owner does no policy of its own; it owns the session and serializes
  access to it, which is why the call lands here rather than on the session
  directly.
  """
  @spec call_tool(GenServer.server(), String.t(), map(), pos_integer()) ::
          {:ok, term()} | {:error, term()}
  def call_tool(owner, tool, args, timeout_ms)
      when is_binary(tool) and is_map(args) and is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(owner, {:call_tool, tool, args, timeout_ms}, timeout_ms + 5_000)
  catch
    # Same contract as `list_tools/1`: a torn-down owner reports a classified
    # error rather than dying with a raw `:noproc` inside the caller's task.
    :exit, {reason, {GenServer, :call, _args}} when reason in [:noproc, :normal, :shutdown] ->
      {:error, :remote_owner_down}
  end

  @doc "Orderly authenticated session teardown, then close. Idempotent."
  @spec teardown(GenServer.server()) :: :ok | {:error, term()}
  def teardown(owner) do
    GenServer.call(owner, :teardown, Timeouts.mcp_remote_teardown() + 5_000)
  catch
    # The owner is already gone or on its way out: the session it owned went
    # with it, which is the postcondition the caller wanted.
    :exit, {reason, {GenServer, :call, _args}} when reason in [:noproc, :normal, :shutdown] ->
      :ok
  end

  @impl true
  def init(opts) do
    # The session is linked; trapping exits is what makes terminate/2 run on the
    # supervisor's shutdown path, which is where the protocol teardown lives.
    Process.flag(:trap_exit, true)

    spec = Keyword.fetch!(opts, :spec)
    source_id = fetch_source_id!(spec)
    status_server = Keyword.get(opts, :runtime_status)
    generation = register(status_server, source_id)

    state = %{
      spec: spec,
      source_id: source_id,
      plugin: plugin_of(source_id),
      runtime_status: status_server,
      generation: generation,
      session_module: Keyword.get(opts, :session, Session),
      session_opts: Keyword.take(opts, [:transport, :connect_opts, :resolver, :client_info]),
      session: nil,
      deadline: System.monotonic_time(:millisecond) + Timeouts.mcp_remote_startup()
    }

    case configure(spec) do
      {:ok, config} -> {:ok, Map.merge(state, config), {:continue, :connect}}
      {:error, reason} -> {:stop, record_refusal(state, reason)}
    end
  end

  @impl true
  def handle_continue(:connect, state) do
    case attempt_connect(state, 1) do
      {:ok, state} -> {:noreply, state}
      {:error, state, reason} -> give_up(state, reason)
    end
  end

  @impl true
  def handle_call(:list_tools, _from, %{session: nil} = state) do
    {:reply, {:error, :remote_not_connected}, state}
  end

  def handle_call(:list_tools, _from, state) do
    {:reply, discover(state), state}
  end

  def handle_call({:call_tool, _tool, _args, _timeout}, _from, %{session: nil} = state) do
    {:reply, {:error, :remote_not_connected}, state}
  end

  def handle_call({:call_tool, tool, args, timeout_ms}, _from, state) do
    params = %{"name" => tool, "arguments" => args}
    {:reply, state.session_module.request(state.session, "tools/call", params, timeout_ms), state}
  end

  def handle_call(:teardown, _from, state) do
    {result, state} = close_session(state)
    {:reply, result, state}
  end

  @impl true
  def handle_info({:EXIT, session, reason}, %{session: session} = state) do
    state = %{state | session: nil}
    {status, detail} = RuntimeStatus.classify(reason)
    _ = put_status(state, status, detail, RuntimeStatus.capability_from(reason))
    Logger.warning("remote MCP session for #{inspect(state.source_id)} exited: #{status}")
    {:stop, :normal, state}
  end

  # An unmatched message must not kill a connection the operator depends on,
  # and its payload is never logged: a stray term here could carry anything.
  def handle_info(message, state) do
    Logger.debug("remote MCP owner ignored #{inspect(message_kind(message))}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    {_result, _state} = close_session(state)
    :ok
  end

  # --- start -------------------------------------------------------------

  defp configure(spec) do
    with :ok <- check_transport(spec),
         :ok <- check_protocol(spec),
         {:ok, endpoint} <- endpoint(spec),
         {:ok, auth_ref} <- auth_ref(spec) do
      {:ok, %{endpoint: endpoint, auth_ref: auth_ref}}
    end
  end

  defp check_transport(%{transport: :streamable_http}), do: :ok

  defp check_transport(spec),
    do: {:error, {:invalid_remote_config, {:transport, Map.get(spec, :transport)}}}

  defp check_protocol(%{protocol_version: version}) do
    if version == Session.protocol_version(),
      do: :ok,
      else: {:error, {:invalid_remote_config, {:protocol_version, version}}}
  end

  defp check_protocol(_spec), do: {:error, {:invalid_remote_config, :protocol_version_missing}}

  defp endpoint(%{base_url: base_url, mcp_path: mcp_path}) do
    case Endpoint.new(base_url, mcp_path) do
      {:ok, endpoint} -> {:ok, endpoint}
      {:error, reason} -> {:error, {:invalid_remote_config, reason}}
    end
  end

  defp endpoint(_spec), do: {:error, {:invalid_remote_config, :endpoint_missing}}

  defp auth_ref(%{auth_ref: %{type: :plugin_secret, plugin: plugin}}), do: AuthRef.new(plugin)

  defp auth_ref(spec),
    do: {:error, {:invalid_remote_config, {:auth_ref, Map.get(spec, :auth_ref)}}}

  defp attempt_connect(state, attempt) do
    started = System.monotonic_time(:millisecond)
    result = start_session(state)
    emit(state, :initialize, tag(result), System.monotonic_time(:millisecond) - started, attempt)
    settle_attempt(state, attempt, result)
  end

  defp settle_attempt(state, _attempt, {:ok, session}), do: {:ok, %{state | session: session}}

  defp settle_attempt(state, attempt, {:error, reason}) do
    if retry?(state, attempt, reason) do
      Process.sleep(@retry_backoff_ms * attempt)
      attempt_connect(state, attempt + 1)
    else
      {:error, state, reason}
    end
  end

  defp start_session(state) do
    opts =
      state.session_opts ++
        [endpoint: state.endpoint, auth_ref: state.auth_ref]

    case state.session_module.start_link(opts) do
      {:ok, session} -> {:ok, session}
      {:error, reason} -> {:error, reason}
      :ignore -> {:error, {:remote_protocol_error, :session_ignored}}
    end
  end

  # Only unreachability is retried. A classified failure — rejected credential,
  # endpoint policy, protocol, contract — cannot become success by repetition,
  # and a 429 answered with an immediate retry is how a rate limit becomes a
  # block.
  defp retry?(state, attempt, reason) do
    attempt < Limits.max_startup_attempts() and transient?(reason) and
      System.monotonic_time(:millisecond) < state.deadline
  end

  defp transient?(reason) do
    case RuntimeStatus.classify(reason) do
      {:remote_unreachable, :rate_limited} -> false
      {:remote_unreachable, _class} -> true
      _classified -> false
    end
  end

  # Giving up after the bounded attempts exits `:normal`: the classified status
  # is already visible and outlives this subtree, and a non-normal exit would
  # respawn the client behind the operator's back.
  defp give_up(state, reason) do
    _classified = record_refusal(state, reason)
    {:stop, :normal, state}
  end

  # Returns the classified reason so an `init/1` refusal can carry it into the
  # start error — the only report a process that never lived can produce.
  defp record_refusal(state, reason) do
    {status, detail} = RuntimeStatus.classify(reason)
    capability = RuntimeStatus.capability_from(reason)
    _ = put_status(state, status, detail, capability)
    maybe_emit_security_block(state, status, detail)

    Logger.error(
      "remote MCP client #{inspect(state.source_id)} refused " <>
        "(#{RuntimeStatus.describe(status, detail, capability)}); " <>
        "config=#{inspect(redacted(state.spec))}"
    )

    {status, detail}
  end

  # --- discovery ---------------------------------------------------------

  defp discover(state) do
    started = System.monotonic_time(:millisecond)
    result = collect_tools(state, nil, [], MapSet.new(), 1)
    emit(state, :discover, tag(result), System.monotonic_time(:millisecond) - started, 1)
    result
  end

  defp collect_tools(state, cursor, acc, seen, page) do
    if page > Limits.max_discovery_pages() do
      {:error, {:remote_protocol_error, :discovery_page_limit}}
    else
      request_page(state, cursor, acc, seen, page)
    end
  end

  defp request_page(state, cursor, acc, seen, page) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}

    case state.session_module.request(
           state.session,
           "tools/list",
           params,
           Timeouts.mcp_remote_discover()
         ) do
      {:ok, result} -> merge_page(state, result, acc, seen, page)
      {:error, reason} -> {:error, reason}
    end
  end

  defp merge_page(state, result, acc, seen, page) do
    with {:ok, tools} <- page_tools(result),
         {:ok, acc} <- accumulate(acc, tools),
         {:ok, cursor} <- next_cursor(result, seen) do
      continue_pages(state, acc, seen, cursor, page)
    end
  end

  defp continue_pages(_state, acc, _seen, nil, _page), do: {:ok, acc}

  defp continue_pages(state, acc, seen, cursor, page) do
    collect_tools(state, cursor, acc, MapSet.put(seen, cursor), page + 1)
  end

  defp page_tools(%{"tools" => tools}) when is_list(tools), do: {:ok, tools}
  defp page_tools(_result), do: {:error, {:invalid_remote_result, :tools_not_a_list}}

  defp accumulate(acc, tools) do
    merged = acc ++ Enum.map(tools, &descriptor/1)

    if length(merged) > Limits.max_discovered_tools(),
      do: {:error, {:remote_protocol_error, :too_many_tools}},
      else: {:ok, merged}
  end

  # One shared definition (see `Discoverer.normalize/1`): the signed descriptor
  # covers outputSchema and annotations too, and a second copy of this function
  # is exactly how the remote path came to hash something the publisher never
  # signed.
  defp descriptor(tool) when is_map(tool), do: Discoverer.normalize(tool)

  # A repeated cursor is an unbounded loop with a polite face on it.
  defp next_cursor(result, seen) do
    case Map.get(result, "nextCursor") do
      nil -> {:ok, nil}
      cursor when is_binary(cursor) -> validate_cursor(cursor, seen)
      _other -> {:error, {:invalid_remote_result, :cursor_not_a_string}}
    end
  end

  defp validate_cursor(cursor, seen) do
    cond do
      byte_size(cursor) > Limits.max_cursor_bytes() ->
        {:error, {:remote_protocol_error, :cursor_too_large}}

      MapSet.member?(seen, cursor) ->
        {:error, {:remote_protocol_error, :cursor_cycle}}

      true ->
        {:ok, cursor}
    end
  end

  # --- teardown ----------------------------------------------------------

  defp close_session(%{session: nil} = state), do: {:ok, state}

  defp close_session(state) do
    started = System.monotonic_time(:millisecond)
    result = state.session_module.teardown(state.session)
    emit(state, :teardown, tag(result), System.monotonic_time(:millisecond) - started, 1)
    log_teardown(state, result)
    stop_session(state.session)
    {result, %{state | session: nil}}
  end

  # The remote session's own destruction is best-effort, but a failure that
  # nobody can see is a failure nobody can diagnose: report it before the local
  # socket closes.
  defp log_teardown(_state, :ok), do: :ok

  defp log_teardown(state, {:error, reason}) do
    {status, detail} = RuntimeStatus.classify(reason)

    Logger.warning(
      "remote MCP teardown for #{inspect(state.source_id)} failed: " <>
        RuntimeStatus.describe(status, detail)
    )
  end

  defp stop_session(session) do
    GenServer.stop(session, :normal, Timeouts.mcp_remote_teardown())
  catch
    :exit, _already_gone -> :ok
  end

  # --- status + telemetry ------------------------------------------------

  defp register(nil, _source_id), do: nil

  defp register(server, source_id) do
    {:ok, generation} =
      RuntimeStatus.register_owner(server, source_id, self(), plugin: plugin_of(source_id))

    generation
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
      :ok ->
        :ok

      # This owner has already been replaced (rotation, reconnect). Its status
      # must not overwrite its replacement's — that is the whole point of the
      # generation — so the write is refused, reported here, and dropped.
      {:error, :stale_generation} ->
        :stale_generation
    end
  end

  defp maybe_emit_security_block(state, :remote_security_blocked, detail) do
    emit(state, :security_block, {:error, detail}, 0, 1)
  end

  defp maybe_emit_security_block(_state, _status, _detail), do: :ok

  defp emit(state, phase, result, duration_ms, attempt) do
    Telemetry.emit_lifecycle(
      phase,
      %{source_id: state.source_id, plugin: state.plugin},
      result,
      max(duration_ms, 0),
      attempt: attempt
    )
  end

  defp tag({:ok, _value}), do: :ok
  defp tag(:ok), do: :ok
  defp tag({:error, reason}), do: {:error, reason}

  defp fetch_source_id!(%{source_id: {kind, name} = source_id})
       when is_atom(kind) and is_binary(name) and name != "",
       do: source_id

  defp fetch_source_id!(spec) do
    raise ArgumentError,
          "remote MCP spec requires source_id: {kind, name}, got: " <>
            inspect(Map.get(spec, :source_id))
  end

  defp plugin_of({:plugin, name}), do: name
  defp plugin_of({_kind, _name}), do: nil

  defp message_kind(message) when is_tuple(message) and tuple_size(message) > 0,
    do: elem(message, 0)

  defp message_kind(message) when is_atom(message), do: message
  defp message_kind(_message), do: :unknown
end
