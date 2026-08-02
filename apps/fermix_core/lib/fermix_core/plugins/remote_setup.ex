defmodule FermixCore.Plugins.RemoteSetup do
  @moduledoc """
  Setup-only resource discovery and the operator's workspace selection for a
  remote MCP plugin (M27 §7.5 steps 6–7, §8.1).

  ## The setup session is not the managed client

  `discover_workspaces/2` starts one bounded `Remote.Session`, uses it for
  exactly two requests, and closes it. That session is **never** published to
  `MCP.Registry`, never registers an owner in `RuntimeStatus`, and none of its
  tools ever becomes a capability.

  That separation is the resource boundary, not an implementation detail. The
  discovery tool enumerates *every* workspace the credential can reach, while
  the call proxy exposes only the one the operator selected. A discovery tool
  the agent could see or call would hand the model exactly the list the scope
  exists to withhold — so it is declared in `setup_tools` (never in a profile),
  and this module refuses a `discovery_tool` that is not a declared setup tool.
  The manifest validator already enforces that; this is the one code path that
  actually calls the tool, so it enforces it again rather than trusting a check
  that lives somewhere else.

  ## What is proven before the call

  The transport shape (pinned protocol version, endpoint policy) and the
  **signed descriptor**: the live `tools/list` entry for the discovery tool must
  canonicalize to the `descriptor_sha256` the manifest signed. A tool whose
  schema drifted is refused, not called with arguments that no longer mean what
  was reviewed.

  ## Locating the list

  The resource list is the JSON array the response carries: the decoded body
  when it *is* an array, otherwise its single array-valued member. Zero arrays,
  or several, is ambiguous and refused — core does not get to guess which array
  in a response is "the workspaces", and picking the first one would make the
  picker's contents depend on JSON key order. The signed `resource_scope` names
  the fields *inside* each entry (`id_field`, `label_field`), not the container,
  so this is the one shape rule, stated once, failing loud.

  ## Changing the selection is a real reconnect

  `select_workspace/2` synchronously stops `{:plugin, name}` and proves it down,
  commits the new selection, restarts the source against a freshly materialized
  spec, and only reports success once that generation reaches `:ready` — the
  contract check included. It uses the source-qualified
  `MCP.Supervisor.stop_server/restart_server`, never `Runtime.reload/1`'s
  best-effort fan-out, whose spec-hash child identity proves nothing about
  which client is actually holding the connection.

  ## What never leaves this module

  The credential, the workspace IDs, and raw response bodies. Telemetry carries
  the lifecycle phase and a derived error class only (`MCP.Telemetry`), and
  every error term here is a class or a byte count — never operator data.
  """

  alias FermixCore.Capabilities.MCP.Remote.AuthRef
  alias FermixCore.Capabilities.MCP.Remote.Endpoint
  alias FermixCore.Capabilities.MCP.Remote.Limits
  alias FermixCore.Capabilities.MCP.Remote.Session
  alias FermixCore.Capabilities.MCP.RuntimeStatus
  alias FermixCore.Capabilities.MCP.Supervisor, as: McpSupervisor
  alias FermixCore.Capabilities.MCP.Telemetry
  alias FermixCore.Plugins.CanonicalJson
  alias FermixCore.Plugins.Config
  alias FermixCore.Plugins.Dist.McpSource
  alias FermixCore.Plugins.Plugin

  alias FermixCore.Timeouts

  # The reviewed MCP content forms for a setup result. Binary blobs, base64
  # media, and embedded resources are refused outright, exactly as they are on
  # the agent-facing call path (§7.9).
  @reviewed_content_types ~w(text)

  # Guard-usable form of the rail's page cap.
  @max_pages Limits.max_discovery_pages()
  @max_status_class_bytes 48

  @type workspace :: %{id: String.t(), label: String.t()}

  @type opt ::
          {:session, module()}
          | {:transport, module()}
          | {:connect_opts, keyword()}
          | {:resolver, (String.t() -> String.t() | nil)}
          | {:client_info, map()}
          | {:mcp_supervisor, module()}
          | {:runtime_status, GenServer.server()}
          | {:task_supervisor, GenServer.server()}

  @doc """
  List the workspaces the plugin's stored credential can reach, for the
  operator to choose from.

  Opts are seams only: `:session`/`:transport`/`:connect_opts`/`:resolver`/
  `:client_info` are forwarded to `Remote.Session`, and `:task_supervisor`
  names the supervisor that owns the short-lived session holder.
  """
  @spec discover_workspaces(Plugin.t(), [opt()]) :: {:ok, [workspace()]} | {:error, term()}
  def discover_workspaces(%Plugin{} = plugin, opts \\ []) when is_list(opts) do
    started = System.monotonic_time(:millisecond)
    result = run_discovery(plugin, opts)
    emit(plugin, :discover, result, System.monotonic_time(:millisecond) - started)
    result
  end

  @doc """
  Commit the operator's selection and reconnect the managed client against it.

  Requires `:workspace_id` and `:workspace_label`; `:access_profile` is
  optional and absent resolves to the manifest's signed default. Success means
  the replacement client reached `:ready` — authenticated *and* contract-checked
  — not that a child process started.
  """
  @spec select_workspace(Plugin.t(), [opt()]) :: :ok | {:error, term()}
  def select_workspace(%Plugin{} = plugin, opts) when is_list(opts) do
    started = System.monotonic_time(:millisecond)
    result = run_selection(plugin, opts)
    emit(plugin, :reconnect, result, System.monotonic_time(:millisecond) - started)
    result
  end

  # --- discovery ---------------------------------------------------------

  defp run_discovery(plugin, opts) do
    with {:ok, setup} <- compile_setup(plugin),
         {:ok, session_opts} <- session_opts(plugin, opts) do
      in_owner(opts, fn -> open_session(session_opts, setup, opts) end)
    end
  end

  # The session is `start_link`ed, so it must be owned by a process whose death
  # is harmless: a refused handshake exits, and that signal would otherwise take
  # the caller — a LiveView task, a CLI process — down with it. The owner task
  # is that process, and because the session is linked to it, the session cannot
  # outlive the attempt even if this call is abandoned.
  defp in_owner(opts, fun) do
    supervisor = Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor)
    budget = Timeouts.mcp_remote_startup()
    task = Task.Supervisor.async_nolink(supervisor, fun)

    case Task.yield(task, budget) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, reason}
      nil -> Timeouts.expired(:mcp_remote_startup, budget)
    end
  end

  defp open_session(session_opts, setup, opts) do
    module = Keyword.get(opts, :session, Session)

    case module.start_link(session_opts) do
      {:ok, session} -> discover_and_close(module, session, setup)
      {:error, reason} -> {:error, reason}
      :ignore -> {:error, {:remote_protocol_error, :session_ignored}}
    end
  end

  # House rule 4, and the reason `after` is used rather than a happy-path close:
  # this session is the only place a resolved bearer credential exists, so it is
  # closed on the error path and on a raise, not just on success.
  defp discover_and_close(module, session, setup) do
    verify_then_call(module, session, setup)
  after
    close_session(module, session)
  end

  defp close_session(module, session) do
    _ = module.teardown(session)
    GenServer.stop(session, :normal, Timeouts.mcp_remote_teardown())
  catch
    :exit, _already_gone -> :ok
  end

  defp verify_then_call(module, session, setup) do
    with {:ok, descriptors} <- list_descriptors(module, session),
         :ok <- verify_descriptor(descriptors, setup),
         {:ok, result} <- call_discovery(module, session, setup),
         {:ok, items} <- items(result, setup) do
      project(items, setup)
    end
  end

  defp call_discovery(module, session, setup) do
    params = %{"name" => setup.name, "arguments" => %{}}

    with {:ok, result} <-
           module.request(session, "tools/call", params, Timeouts.mcp_remote_call()) do
      refuse_tool_error(result, setup)
    end
  end

  # §7.9: a successful JSON-RPC envelope is not a successful tool call.
  defp refuse_tool_error(%{"isError" => true} = result, setup) do
    {:error, {:remote_tool_error, status_class(result, setup)}}
  end

  defp refuse_tool_error(result, _setup) when is_map(result), do: {:ok, result}
  defp refuse_tool_error(_result, _setup), do: {:error, {:invalid_remote_result, :not_an_object}}

  # --- bounded tools/list ------------------------------------------------

  defp list_descriptors(module, session), do: collect(module, session, nil, [], MapSet.new(), 1)

  defp collect(_module, _session, _cursor, _acc, _seen, page)
       when page > @max_pages,
       do: {:error, {:remote_protocol_error, :discovery_page_limit}}

  defp collect(module, session, cursor, acc, seen, page) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}

    with {:ok, result} <-
           module.request(session, "tools/list", params, Timeouts.mcp_remote_discover()),
         {:ok, tools} <- page_tools(result),
         {:ok, acc} <- accumulate(acc, tools),
         {:ok, next} <- next_cursor(result, seen) do
      continue(module, session, acc, seen, next, page)
    end
  end

  defp continue(_module, _session, acc, _seen, nil, _page), do: {:ok, acc}

  defp continue(module, session, acc, seen, cursor, page),
    do: collect(module, session, cursor, acc, MapSet.put(seen, cursor), page + 1)

  defp page_tools(%{"tools" => tools}) when is_list(tools), do: {:ok, tools}
  defp page_tools(_result), do: {:error, {:invalid_remote_result, :tools_not_a_list}}

  defp accumulate(acc, tools) do
    merged = acc ++ Enum.filter(tools, &is_map/1)

    if length(merged) > Limits.max_discovered_tools(),
      do: {:error, {:remote_protocol_error, :too_many_tools}},
      else: {:ok, merged}
  end

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

  # --- signed descriptor -------------------------------------------------

  defp verify_descriptor(descriptors, setup) do
    case Enum.filter(descriptors, &(Map.get(&1, "name") == setup.name)) do
      [descriptor] -> match_digest(descriptor, setup)
      [] -> {:error, {:upstream_contract_mismatch, {:missing_tool, setup.name}}}
      _duplicates -> {:error, {:upstream_contract_mismatch, {:duplicate_tool, setup.name}}}
    end
  end

  defp match_digest(%{"inputSchema" => input} = descriptor, setup) when is_map(input) do
    case CanonicalJson.descriptor_digest(
           setup.name,
           input,
           Map.get(descriptor, "outputSchema"),
           Map.get(descriptor, "annotations")
         ) do
      {:ok, digest} -> compare_digest(digest, setup)
      {:error, _reason} -> mismatch(:uncanonicalizable, setup)
    end
  end

  defp match_digest(_descriptor, setup), do: mismatch(:invalid_schema, setup)

  defp compare_digest(digest, setup) do
    if digest == setup.descriptor_sha256, do: :ok, else: mismatch(:descriptor_changed, setup)
  end

  defp mismatch(class, setup),
    do: {:error, {:upstream_contract_mismatch, {class, setup.name}}}

  # --- result → workspaces -----------------------------------------------

  defp items(result, _setup) do
    with {:ok, body} <- body(result), do: locate_list(body)
  end

  defp locate_list(body) when is_list(body), do: bound_items(body)

  defp locate_list(body) when is_map(body) do
    case Enum.filter(Map.values(body), &is_list/1) do
      [items] -> bound_items(items)
      [] -> {:error, {:invalid_remote_result, :no_resource_list}}
      _several -> {:error, {:invalid_remote_result, :ambiguous_resource_list}}
    end
  end

  defp body(%{"structuredContent" => %{} = structured}), do: {:ok, structured}
  defp body(%{"content" => content}) when is_list(content), do: decode_text(content)
  defp body(_result), do: {:error, {:invalid_remote_result, :no_content}}

  defp decode_text(content) do
    with {:ok, chunks} <- reviewed_chunks(content) do
      chunks |> Enum.join("\n") |> decode_json()
    end
  end

  defp reviewed_chunks(content) do
    Enum.reduce_while(content, {:ok, []}, fn block, {:ok, acc} ->
      case block do
        %{"type" => type, "text" => text}
        when type in @reviewed_content_types and is_binary(text) ->
          {:cont, {:ok, acc ++ [text]}}

        _unsupported ->
          {:halt, {:error, {:invalid_remote_result, :unsupported_content}}}
      end
    end)
  end

  defp decode_json(text) do
    case Jason.decode(text) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, decoded} when is_list(decoded) -> {:ok, decoded}
      _undecodable -> {:error, {:invalid_remote_result, :not_json}}
    end
  end

  # The rail's existing bound on a single upstream listing. Exceeding it fails
  # visibly: a truncated workspace list is a picker that silently hides the
  # workspace the operator was looking for.
  defp bound_items(items) do
    if length(items) > Limits.max_discovered_tools(),
      do: {:error, {:remote_protocol_error, :too_many_resources}},
      else: {:ok, items}
  end

  defp project(items, setup) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case workspace(item, setup) do
        {:ok, workspace} -> {:cont, {:ok, [workspace | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Projected with the same rules the selection is persisted under: offering a
  # workspace that could not then be saved is a picker that lies.
  defp workspace(item, setup) when is_map(item) do
    with {:ok, id} <- Config.validate_workspace_id(Map.get(item, setup.id_field)),
         {:ok, label} <- Config.validate_workspace_label(Map.get(item, setup.label_field)) do
      {:ok, %{id: id, label: label}}
    end
  end

  defp workspace(_item, _setup), do: {:error, {:invalid_remote_result, :resource_not_an_object}}

  # --- manifest → setup facts --------------------------------------------

  defp compile_setup(%Plugin{} = plugin) do
    with {:ok, scope} <- resource_scope(plugin),
         {:ok, tool} <- discovery_tool(plugin, scope),
         {:ok, digest} <- descriptor_sha256(tool) do
      {:ok,
       %{
         name: Map.fetch!(tool, "name"),
         descriptor_sha256: digest,
         id_field: Map.fetch!(scope, "id_field"),
         label_field: Map.fetch!(scope, "label_field"),
         status_field: status_field(plugin)
       }}
    end
  end

  defp resource_scope(%Plugin{resource_scope: %{} = scope} = plugin) do
    fields = ~w(kind discovery_tool id_field label_field)

    if Enum.all?(fields, &is_binary(Map.get(scope, &1))),
      do: {:ok, scope},
      else: {:error, {:invalid_remote_config, {:resource_scope, plugin.name}}}
  end

  defp resource_scope(%Plugin{name: name}),
    do: {:error, {:invalid_remote_config, {:resource_scope_missing, name}}}

  defp discovery_tool(%Plugin{} = plugin, scope) do
    name = Map.fetch!(scope, "discovery_tool")

    if name in plugin.setup_tools,
      do: fetch_tool(plugin, name),
      else: {:error, {:invalid_remote_config, {:discovery_tool_not_setup_only, name}}}
  end

  defp fetch_tool(%Plugin{tools: tools}, name) do
    case Enum.find(tools, &(is_map(&1) and Map.get(&1, "name") == name)) do
      %{} = tool -> {:ok, tool}
      nil -> {:error, {:invalid_remote_config, {:undeclared_discovery_tool, name}}}
    end
  end

  defp descriptor_sha256(tool) do
    case Map.get(tool, "descriptor_sha256") do
      digest when is_binary(digest) and byte_size(digest) == 64 -> {:ok, digest}
      _invalid -> {:error, {:invalid_remote_config, {:descriptor_sha256, tool["name"]}}}
    end
  end

  defp status_field(%Plugin{result_contract: %{"status_field" => field}}) when is_binary(field),
    do: field

  defp status_field(%Plugin{}), do: nil

  # --- session construction ----------------------------------------------

  defp session_opts(%Plugin{runtime: runtime} = plugin, opts) when is_map(runtime) do
    with :ok <- check(Map.get(runtime, "transport") == "streamable_http", :transport),
         :ok <-
           check(
             Map.get(runtime, "protocol_version") == Session.protocol_version(),
             :protocol_version
           ),
         {:ok, endpoint} <- endpoint(runtime),
         {:ok, auth_ref} <- auth_ref(plugin) do
      forwarded = Keyword.take(opts, [:transport, :connect_opts, :resolver, :client_info])
      {:ok, [endpoint: endpoint, auth_ref: auth_ref] ++ forwarded}
    end
  end

  defp session_opts(%Plugin{name: name}, _opts),
    do: {:error, {:invalid_remote_config, {:no_runtime, name}}}

  defp endpoint(runtime) do
    case Endpoint.new(Map.get(runtime, "base_url"), Map.get(runtime, "mcp_path")) do
      {:ok, endpoint} -> {:ok, endpoint}
      {:error, reason} -> {:error, {:invalid_remote_config, reason}}
    end
  end

  defp auth_ref(%Plugin{auth: auth, name: name}) do
    case AuthRef.from_auth(auth, name) do
      {:ok, auth_ref} -> {:ok, auth_ref}
      {:error, reason} -> {:error, {:invalid_remote_config, reason}}
    end
  end

  # --- selection ---------------------------------------------------------

  defp run_selection(plugin, opts) do
    with :ok <- stop_client(plugin, opts),
         {:ok, _snapshot} <- persist_selection(plugin, opts),
         {:ok, spec} <- McpSource.remote_spec(plugin),
         {:ok, _pid} <- restart_client(plugin, spec, opts) do
      await_ready(plugin, opts)
    end
  end

  # Stop FIRST and prove it (§7.5): a commit that lands while the previous
  # client is still connected leaves an authenticated session scoped to the
  # workspace the operator just replaced.
  defp stop_client(plugin, opts), do: supervisor_module(opts).stop_server(source_id(plugin))

  defp restart_client(plugin, spec, opts),
    do: supervisor_module(opts).restart_server(source_id(plugin), spec)

  defp supervisor_module(opts), do: Keyword.get(opts, :mcp_supervisor, McpSupervisor)

  defp persist_selection(%Plugin{name: name}, opts) do
    Config.set_workspace_selection(
      name,
      Keyword.take(opts, [:access_profile, :workspace_id, :workspace_label])
    )
  end

  # Success is `:ready` for THIS generation: authenticated and contract-checked.
  # A started child process is not a connected one, and a `:ready` written by
  # the generation we just replaced is precisely the stale answer the
  # generation guard exists to refuse.
  defp await_ready(plugin, opts) do
    server = Keyword.get(opts, :runtime_status, RuntimeStatus)
    source_id = source_id(plugin)

    case RuntimeStatus.owner(server, source_id) do
      {:ok, _owner, generation} -> settle(await(server, source_id, generation))
      :error -> {:error, {:reconnect_not_proven, plugin.name}}
    end
  end

  defp await(server, source_id, generation),
    do: RuntimeStatus.await(server, source_id, generation, Timeouts.mcp_remote_startup())

  defp settle({:ok, :ready}), do: :ok
  defp settle({:error, reason}), do: {:error, reason}

  # --- shared ------------------------------------------------------------

  defp source_id(%Plugin{name: name}), do: {:plugin, name}

  defp emit(%Plugin{name: name}, phase, result, duration_ms) do
    Telemetry.emit_lifecycle(
      phase,
      %{source_id: {:plugin, name}, plugin: name},
      tag(result),
      max(duration_ms, 0)
    )
  end

  defp tag(:ok), do: :ok
  defp tag({:ok, _value}), do: :ok
  defp tag({:error, reason}), do: {:error, reason}

  # The status token is the one part of an error body that is safe to surface:
  # a short machine enum (`auth-expired`, `missing-workspace`). Anything else
  # collapses to a class, and it stays a BINARY — a peer-controlled string
  # turned into an atom is an atom-table leak the peer gets to drive.
  defp status_class(result, %{status_field: field}) when is_binary(field) do
    case result |> error_body() |> Map.get(field) do
      status when is_binary(status) -> safe_class(status)
      _absent -> "unspecified"
    end
  end

  defp status_class(_result, _setup), do: "unspecified"

  defp error_body(result) do
    case body(result) do
      {:ok, %{} = decoded} -> decoded
      _undecodable -> %{}
    end
  end

  defp safe_class(status) do
    if byte_size(status) <= @max_status_class_bytes and Regex.match?(~r/^[a-z0-9_-]+$/, status),
      do: status,
      else: "unspecified"
  end

  defp check(true, _field), do: :ok
  defp check(false, field), do: {:error, {:invalid_remote_config, field}}
end
