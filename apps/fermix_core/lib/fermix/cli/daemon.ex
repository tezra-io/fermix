defmodule Fermix.CLI.Daemon do
  @moduledoc """
  Control-socket listener for `fermix status` and `fermix stop`.

  Listens on a Unix domain socket at `~/.fermix/daemon.sock` (user
  scope) or `/var/run/fermix.sock` (system scope) and serves a tiny
  4-byte-length-prefixed JSON request/response protocol. Core methods include:

      {"method":"status"}    -> {"status":"ok","version":"...","uptime_ms":N}
      {"method":"shutdown"}  -> {"status":"shutting_down"}  then :init.stop()

  Mobile pairing and device-management methods are routed through an injected
  channels-side provider so this core application never compile-depends on
  `fermix_channels`.

  Started only inside `fermix run` (the supervision tree branches on
  `:fermix_core, :daemon_socket_enabled`). Stale sockets from prior
  crashes are removed on boot; double-binding fails fast on
  EADDRINUSE rather than silently overwriting.
  """

  use GenServer

  alias FermixCore.Agents.MainAgent
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.MCP.RuntimeStatus, as: McpRuntimeStatus
  alias FermixCore.Health
  alias FermixCore.Introspection.Agents
  alias FermixCore.Introspection.Capabilities
  alias FermixCore.Introspection.Overview
  alias FermixCore.Introspection.Wire
  alias FermixCore.Observability
  alias FermixCore.Plugins.Runtime, as: PluginsRuntime
  alias FermixCore.Trace

  require Logger

  @recv_timeout_ms 5_000
  @accept_idle_ms 200
  @skill_name_pattern ~r/^[A-Za-z0-9_-]{1,64}$/
  @skill_view_max_bytes 65_536
  @mobile_pair_wait_ms 120_000
  @mobile_pair_task_timeout_ms @mobile_pair_wait_ms + 2_000
  @session_id_pattern ~r/^[A-Za-z0-9_-]{1,128}$/
  @uuid_pattern ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
  # Upper bound on one request frame. A corrupt or version-skewed header
  # (e.g. an old line-framed client's JSON read as a ~2 GB length) fails
  # immediately with :emsgsize instead of buffering until timeout.
  @max_frame_bytes 4_194_304

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    socket_path = Keyword.get(opts, :socket_path, default_socket_path())
    task_supervisor = Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor)
    plugins_runtime = Keyword.get(opts, :plugins_runtime, PluginsRuntime)
    runtime_status = Keyword.get(opts, :runtime_status, McpRuntimeStatus)
    mobile_provider = Keyword.get(opts, :mobile_provider)

    File.mkdir_p!(Path.dirname(socket_path))

    case clear_stale_socket(socket_path) do
      :ok ->
        do_listen(socket_path, task_supervisor, plugins_runtime, runtime_status, mobile_provider)

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp do_listen(socket_path, task_supervisor, plugins_runtime, runtime_status, mobile_provider) do
    listen_opts = [
      :binary,
      {:active, false},
      {:ifaddr, {:local, socket_path}},
      {:packet, 4},
      {:packet_size, @max_frame_bytes},
      {:reuseaddr, true}
    ]

    case :gen_tcp.listen(0, listen_opts) do
      {:ok, listen_socket} ->
        File.chmod!(socket_path, 0o600)
        Logger.info("Daemon control socket listening at #{socket_path}")
        Process.send_after(self(), :accept, 0)

        {:ok,
         %{
           listen_socket: listen_socket,
           socket_path: socket_path,
           task_supervisor: task_supervisor,
           plugins_runtime: plugins_runtime,
           runtime_status: runtime_status,
           mobile_provider: mobile_provider,
           started_at_ms: System.monotonic_time(:millisecond)
         }}

      {:error, reason} ->
        {:stop, {:listen_failed, reason, socket_path}}
    end
  end

  # If the socket file exists, probe it before deleting. A live daemon
  # answers; a stale socket from a previous crash refuses or errors.
  # Unlinking a live socket would let us bind the same path while the
  # original daemon stays running but unreachable via status/stop.
  defp clear_stale_socket(socket_path) do
    cond do
      not File.exists?(socket_path) -> :ok
      live_daemon?(socket_path) -> {:error, {:another_daemon_running, socket_path}}
      true -> rm_stale(socket_path)
    end
  end

  defp live_daemon?(socket_path) do
    case :gen_tcp.connect(
           {:local, to_charlist(socket_path)},
           0,
           [:binary, {:active, false}, {:packet, 4}],
           500
         ) do
      {:ok, conn} ->
        _ = :gen_tcp.close(conn)
        true

      {:error, _} ->
        false
    end
  end

  defp rm_stale(socket_path) do
    case File.rm(socket_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:stale_socket_unlink_failed, reason, socket_path}}
    end
  end

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.listen_socket, @accept_idle_ms) do
      {:ok, conn} ->
        spawn_handler(state, conn)
        send(self(), :accept)
        {:noreply, state}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, :closed} ->
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.warning("Daemon accept error: #{inspect(reason)}")
        Process.send_after(self(), :accept, 1_000)
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, %{listen_socket: socket, socket_path: path}) do
    _ = :gen_tcp.close(socket)
    _ = File.rm(path)
    :ok
  end

  defp spawn_handler(%{task_supervisor: sup} = state, conn) do
    case Task.Supervisor.start_child(sup, fn -> await_socket_handoff() end) do
      {:ok, pid} -> handoff_socket(conn, pid, state)
      {:error, reason} -> close_unhandled_socket(conn, reason)
    end
  end

  defp await_socket_handoff do
    receive do
      {:serve_daemon_socket, conn, state} -> handle_connection(conn, state)
      {:abort_daemon_socket, _reason} -> :ok
    after
      @recv_timeout_ms -> :ok
    end
  end

  defp handoff_socket(conn, pid, state) do
    case :gen_tcp.controlling_process(conn, pid) do
      :ok ->
        send(pid, {:serve_daemon_socket, conn, state})

      {:error, reason} ->
        send(pid, {:abort_daemon_socket, reason})
        close_unhandled_socket(conn, reason)
    end
  end

  defp close_unhandled_socket(conn, reason) do
    Logger.warning("Daemon connection handoff failed: #{inspect(reason)}")
    :gen_tcp.close(conn)
  end

  defp handle_connection(conn, state) do
    case receive_request(conn, @recv_timeout_ms) do
      {:ok, request} -> handle_initial_request(conn, request, state)
      {:error, :invalid_request} -> send_response(conn, invalid_request_reply())
      {:error, _reason} -> :ok
    end
  after
    :gen_tcp.close(conn)
  end

  defp receive_request(conn, timeout_ms) do
    with {:ok, frame} <- :gen_tcp.recv(conn, 0, timeout_ms),
         {:ok, request} <- decode_request(frame) do
      {:ok, request}
    end
  end

  defp decode_request(frame) do
    # The local control socket has no per-request auth; the trust boundary is
    # the 0600 socket file under FERMIX_HOME. `agent_message` is a deliberate
    # operator action from `fermix ask`, and can trigger LLM/tool work.
    case Jason.decode(String.trim(frame)) do
      {:ok, %{"method" => method} = request} when is_binary(method) -> {:ok, request}
      _ -> {:error, :invalid_request}
    end
  end

  defp handle_initial_request(conn, request, state) do
    response = dispatch_request(request, state)

    case opened_pair_session(request, response) do
      {:ok, session_id} -> handle_pair_lease(conn, response, session_id, state)
      :none -> send_response(conn, response)
    end

    maybe_finalize(response)
  end

  defp dispatch_request(%{"method" => method} = request, state),
    do: handle_method(method, request, state)

  defp opened_pair_session(%{"method" => "mobile_pair_begin"}, %{status: "ok"} = response) do
    case response |> Map.get(:result, %{}) |> map_value(:session_id) do
      session_id when is_binary(session_id) -> {:ok, session_id}
      _invalid -> :none
    end
  end

  defp opened_pair_session(_request, _response), do: :none

  defp handle_pair_lease(conn, begin_response, session_id, state) do
    lease_key = {:fermix_mobile_pair_lease, make_ref()}
    Process.put(lease_key, session_id)

    try do
      with :ok <- send_response(conn, begin_response) do
        pair_request_loop(conn, state, session_id, lease_key)
      end
    after
      lease_key
      |> Process.delete()
      |> cancel_abandoned_pair(state)
    end
  end

  defp pair_request_loop(conn, state, session_id, lease_key) do
    case receive_request(conn, @mobile_pair_wait_ms) do
      {:ok, request} -> handle_pair_request(conn, request, state, session_id, lease_key)
      {:error, :invalid_request} -> send_response(conn, invalid_request_reply())
      {:error, _reason} -> :ok
    end
  end

  defp handle_pair_request(conn, %{"method" => method} = request, state, session_id, lease_key)
       when method in ["mobile_pair_wait", "mobile_pair_decide", "mobile_pair_cancel"] do
    with :ok <- require_pair_session(request, session_id) do
      dispatch_pair_request(conn, request, state, session_id, lease_key)
    else
      {:error, reason} -> send_response(conn, error_reply(reason))
    end
  end

  defp handle_pair_request(conn, _request, _state, _session_id, _lease_key) do
    send_response(conn, error_reply(:pair_connection_method_not_allowed))
  end

  defp dispatch_pair_request(
         conn,
         %{"method" => "mobile_pair_wait"} = request,
         state,
         session_id,
         lease_key
       ) do
    case interruptible_pair_wait(conn, request, state) do
      {:ok, response} ->
        with :ok <- send_response(conn, response) do
          pair_request_loop(conn, state, session_id, lease_key)
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp dispatch_pair_request(conn, request, state, session_id, lease_key) do
    response = dispatch_request(request, state)

    if successful_reply?(response) do
      _session_id = Process.delete(lease_key)
      send_response(conn, response)
    else
      with :ok <- send_response(conn, response) do
        pair_request_loop(conn, state, session_id, lease_key)
      end
    end
  end

  defp interruptible_pair_wait(conn, request, state) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        dispatch_request(request, state)
      end)

    case :inet.setopts(conn, active: :once) do
      :ok -> await_pair_wait(conn, task)
      {:error, reason} -> stop_pair_wait(task, reason)
    end
  end

  defp await_pair_wait(conn, task) do
    receive do
      {ref, response} when ref == task.ref ->
        Process.demonitor(task.ref, [:flush])
        pair_wait_response(conn, response)

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        pair_wait_response(conn, error_reply({:pair_wait_failed, reason}))

      {:tcp_closed, ^conn} ->
        stop_pair_wait(task, :closed)

      {:tcp_error, ^conn, reason} ->
        stop_pair_wait(task, reason)

      {:tcp, ^conn, _unexpected_frame} ->
        stop_pair_wait(task, :pipelined_pair_request)
    after
      @mobile_pair_task_timeout_ms -> stop_pair_wait(task, :pair_wait_timeout)
    end
  end

  defp pair_wait_response(conn, response) do
    case :inet.setopts(conn, active: false) do
      :ok -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stop_pair_wait(task, reason) do
    _ = Task.shutdown(task, :brutal_kill)
    {:error, reason}
  end

  defp require_pair_session(request, expected) do
    case mobile_session_id(request) do
      {:ok, ^expected} -> :ok
      {:ok, _other} -> {:error, :pair_session_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cancel_abandoned_pair(nil, _state), do: :ok

  defp cancel_abandoned_pair(session_id, state) do
    case mobile_call(state, :cancel_pairing, [session_id]) do
      %{status: "ok"} ->
        :ok

      response ->
        Logger.warning(
          "Failed to cancel abandoned mobile pairing #{session_id}: #{inspect(response)}"
        )
    end
  end

  defp send_response(conn, response), do: :gen_tcp.send(conn, Jason.encode!(response))
  defp invalid_request_reply, do: %{status: "error", reason: "invalid request"}
  defp successful_reply?(%{status: "ok"}), do: true
  defp successful_reply?(_response), do: false
  defp map_value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp handle_method("status", _request, state), do: status_reply(state)
  defp handle_method("overview", _request, state), do: overview_reply(state)
  defp handle_method("health", _request, _state), do: health_reply()
  defp handle_method("agents", _request, _state), do: agents_reply()
  defp handle_method("capabilities", request, _state), do: capabilities_reply(request)
  defp handle_method("skills_list", _request, _state), do: skills_list_reply()
  defp handle_method("skills_view", request, _state), do: skills_view_reply(request)
  defp handle_method("skills_reload", _request, _state), do: skills_reload_reply()
  defp handle_method("plugins_apply", _request, state), do: plugins_apply_reply(state)

  defp handle_method("plugins_runtime_status", _request, state),
    do: plugins_runtime_status_reply(state)

  defp handle_method("agent_message", request, _state), do: agent_message_reply(request)
  defp handle_method("observability", _request, _state), do: observability_reply()
  defp handle_method("mobile_pair_begin", _request, state), do: mobile_begin_reply(state)
  defp handle_method("mobile_pair_wait", request, state), do: mobile_wait_reply(request, state)

  defp handle_method("mobile_pair_decide", request, state),
    do: mobile_decide_reply(request, state)

  defp handle_method("mobile_pair_cancel", request, state),
    do: mobile_cancel_reply(request, state)

  defp handle_method("mobile_devices_list", _request, state), do: mobile_list_reply(state)

  defp handle_method("mobile_device_revoke", request, state),
    do: mobile_revoke_reply(request, state)

  defp handle_method("mobile_status", _request, state), do: mobile_status_reply(state)

  defp handle_method("shutdown", _request, _state) do
    Trace.record(:agent_event, "daemon", %{event: "shutdown_requested"})
    %{status: "shutting_down"}
  end

  defp handle_method(method, _request, _state) do
    %{status: "error", reason: "unknown method", method: method}
  end

  defp mobile_begin_reply(state) do
    mobile_call(state, :begin_pairing, [])
  end

  defp mobile_wait_reply(request, state) do
    with {:ok, session_id} <- mobile_session_id(request) do
      mobile_call(state, :await_pairing, [session_id, @mobile_pair_wait_ms])
    else
      {:error, reason} -> error_reply(reason)
    end
  end

  defp mobile_decide_reply(request, state) do
    with {:ok, session_id} <- mobile_session_id(request),
         {:ok, approved?} <- mobile_approval(request) do
      mobile_call(state, :decide_pairing, [session_id, approved?])
    else
      {:error, reason} -> error_reply(reason)
    end
  end

  defp mobile_cancel_reply(request, state) do
    with {:ok, session_id} <- mobile_session_id(request) do
      mobile_call(state, :cancel_pairing, [session_id])
    else
      {:error, reason} -> error_reply(reason)
    end
  end

  defp mobile_list_reply(state), do: mobile_call(state, :list_devices, [])

  defp mobile_revoke_reply(request, state) do
    case request |> request_params() |> Map.get("device_id") do
      device_id when is_binary(device_id) ->
        if Regex.match?(@uuid_pattern, device_id) do
          mobile_call(state, :revoke_device, [String.downcase(device_id)])
        else
          error_reply("invalid device_id")
        end

      _ ->
        error_reply("invalid device_id")
    end
  end

  defp mobile_status_reply(state), do: mobile_call(state, :status, [])

  defp mobile_call(state, function, args) do
    provider = state.mobile_provider || runtime_mobile_provider()

    if mobile_provider_available?(provider, function, length(args)) do
      provider |> call_mobile_provider(function, args) |> mobile_provider_reply()
    else
      error_reply({:mobile_provider_unavailable, provider, function, length(args)})
    end
  end

  defp call_mobile_provider(provider, function, args) do
    safe_daemon_call(fn -> apply(provider, function, args) end)
  end

  defp mobile_provider_reply({:ok, {:ok, result}}) when is_map(result) do
    %{status: "ok", result: Wire.json_safe(result)}
  end

  defp mobile_provider_reply({:ok, {:error, reason}}), do: error_reply(reason)

  defp mobile_provider_reply({:ok, other}),
    do: error_reply({:invalid_mobile_provider_reply, other})

  defp mobile_provider_reply({:error, reason}), do: error_reply(reason)

  defp mobile_provider_available?(provider, function, arity)
       when is_atom(provider) and is_atom(function) and is_integer(arity) do
    Code.ensure_loaded?(provider) and function_exported?(provider, function, arity)
  end

  defp mobile_session_id(request) do
    case Map.get(request_params(request), "session_id") do
      value when is_binary(value) ->
        if Regex.match?(@session_id_pattern, value),
          do: {:ok, value},
          else: {:error, "invalid session_id"}

      _ ->
        {:error, "invalid session_id"}
    end
  end

  defp mobile_approval(request) do
    case Map.get(request_params(request), "approved") do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, "invalid approved flag"}
    end
  end

  defp request_params(request) do
    case Map.get(request, "params", %{}) do
      params when is_map(params) -> params
      _ -> %{}
    end
  end

  defp error_reply(reason), do: %{status: "error", reason: reason_to_string(reason)}

  defp runtime_mobile_provider,
    do: Application.get_env(:fermix_core, :mobile_management_provider)

  defp status_reply(state) do
    %{
      status: "ok",
      version: to_string(Application.spec(:fermix_core, :vsn) || "unknown"),
      uptime_ms: System.monotonic_time(:millisecond) - state.started_at_ms,
      pid: System.pid()
    }
  end

  defp overview_reply(state) do
    with {:ok, overview} <- Overview.snapshot(daemon: daemon_snapshot(state)) do
      %{status: "ok", overview: Wire.json_safe(overview)}
    else
      {:error, reason} -> %{status: "error", reason: inspect(reason)}
    end
  end

  defp health_reply do
    %{status: "ok", health: Health.report() |> Wire.json_safe()}
  end

  # Answered from the daemon process so env/loaded-app/handler state reflect the
  # daemon, not the CLI that asked. Jason renders the atom status as a string.
  defp observability_reply do
    %{status: "ok", observability: Observability.report()}
  end

  defp agents_reply do
    with {:ok, agents} <- Agents.snapshot() do
      %{status: "ok", agents: Wire.json_safe(agents)}
    else
      {:error, reason} -> %{status: "error", reason: inspect(reason)}
    end
  end

  defp capabilities_reply(request) do
    kind = request |> Map.get("params", %{}) |> Map.get("kind", "all")

    with {:ok, capabilities} <- Capabilities.snapshot(kind: kind) do
      %{status: "ok", capabilities: Wire.json_safe(capabilities)}
    else
      {:error, reason} -> %{status: "error", reason: inspect(reason)}
    end
  end

  defp skills_list_reply do
    case safe_daemon_call(fn -> SkillRegistry.snapshot() end) do
      {:ok, {:ok, snapshot}} ->
        %{status: "ok", skills: skill_snapshot(snapshot)}

      {:error, reason} ->
        %{status: "error", reason: inspect(reason)}
    end
  end

  defp skills_view_reply(request) do
    name = request |> Map.get("params", %{}) |> Map.get("name", "") |> to_string()

    with :ok <- validate_skill_name(name),
         {:ok, {:ok, definition}} <- safe_daemon_call(fn -> SkillRegistry.load(name) end),
         :ok <- within_skill_view_size(definition) do
      %{status: "ok", skill: skill_detail(definition)}
    else
      {:ok, {:error, {:unknown_skill, skill_name}}} ->
        %{status: "error", reason: "unknown_skill: #{skill_name}"}

      {:error, reason} ->
        %{status: "error", reason: inspect(reason)}
    end
  end

  defp within_skill_view_size(%{system_prompt: body}) when is_binary(body) do
    if byte_size(body) <= @skill_view_max_bytes do
      :ok
    else
      {:error,
       "skill_body_too_large: #{byte_size(body)} bytes exceeds #{@skill_view_max_bytes}; " <>
         "split the skill or move long references into separate files"}
    end
  end

  defp skills_reload_reply do
    case safe_daemon_call(fn -> MainAgent.reload_skills() end) do
      {:ok, {:ok, summary}} ->
        %{status: "ok", reload: reload_summary(summary)}

      {:ok, {:error, reason}} ->
        %{status: "error", reason: inspect(reason)}

      {:error, reason} ->
        %{status: "error", reason: inspect(reason)}
    end
  end

  # Re-read persisted config from disk and fan the reload out to the daemon's
  # runtime surfaces. This is how a sibling CLI VM's plugin mutations
  # (install/enable/disable/uninstall/...) reach the running daemon.
  defp plugins_apply_reply(state) do
    case safe_daemon_call(fn -> state.plugins_runtime.apply_persisted() end) do
      {:ok, {:ok, summary}} -> %{status: "ok", reload: plugins_apply_summary(summary)}
      {:ok, {:error, reason}} -> %{status: "error", reason: inspect(reason)}
      {:error, reason} -> %{status: "error", reason: inspect(reason)}
    end
  end

  # The skill surfaces of the runtime summary are raw SkillRegistry reload
  # summaries whose `errors` hold tuples — Wire.json_safe raises on tuples, so
  # shape them through the same picker skills_reload uses before serializing.
  defp plugins_apply_summary(summary) do
    %{
      capabilities: Wire.json_safe(Map.get(summary, :capabilities)),
      skills: skill_surface(Map.get(summary, :skills)),
      main_agent: skill_surface(Map.get(summary, :main_agent)),
      realtime: Wire.json_safe(Map.get(summary, :realtime))
    }
  end

  defp skill_surface(summary) when is_map(summary), do: reload_summary(summary)
  defp skill_surface(other), do: Wire.json_safe(other)

  # The live remote-MCP status table (M27 §7.8) lives in THIS process's memory.
  # A one-shot CLI VM (`fermix doctor`, `fermix plugins status`) has no such
  # table, so this op is the only honest way for it to learn a remote plugin's
  # runtime state — the alternative, reading a locally absent table, would
  # report every remote plugin as never-connected or, worse, infer `:ready`.
  defp plugins_runtime_status_reply(state) do
    case safe_daemon_call(fn -> McpRuntimeStatus.list(state.runtime_status) end) do
      {:ok, entries} -> %{status: "ok", runtime_status: runtime_status_rows(entries)}
      {:error, reason} -> %{status: "error", reason: inspect(reason)}
    end
  end

  # Entries are keyed by the source-qualified `{:plugin, "eden"}` id and carry a
  # `generation_ref`, an owner pid, and a monitor ref — `Wire.json_safe/1` RAISES
  # on the tuple key and on both refs. Flatten to a list, render the id as the
  # same stable string the lifecycle telemetry uses ("plugin:eden"), and drop the
  # generation/owner: neither is an operator-facing fact, and §11.1 forbids
  # exporting generation references at all.
  defp runtime_status_rows(entries) do
    Enum.map(entries, fn {{kind, name}, entry} ->
      %{
        source: "#{kind}:#{name}",
        plugin: Wire.json_safe(Map.get(entry, :plugin)),
        status: Wire.json_safe(Map.get(entry, :status)),
        detail: Wire.json_safe(Map.get(entry, :detail)),
        capability: Wire.json_safe(Map.get(entry, :capability)),
        updated_at: Wire.json_safe(Map.get(entry, :updated_at))
      }
    end)
  end

  defp agent_message_reply(request) do
    params = Map.get(request, "params", %{})
    content = params |> Map.get("content", "") |> to_string() |> String.trim()
    session_id = normalize_session_id(Map.get(params, "session_id"))

    timeout_ms =
      normalize_timeout_ms(
        Map.get(params, "timeout_ms"),
        cli_channel_bridge().default_timeout_ms()
      )

    case decode_images(Map.get(params, "images", [])) do
      {:ok, media_parts} ->
        if content == "" and media_parts == [] do
          %{status: "error", error: "empty_input", session_id: session_id}
        else
          cli_bridge_reply(content,
            session_id: session_id,
            timeout_ms: timeout_ms,
            media_parts: media_parts,
            cwd: Map.get(params, "cwd")
          )
        end

      {:error, reason} ->
        %{status: "error", error: reason_to_string(reason), session_id: session_id}
    end
  end

  # Decode `fermix ask --attach` image payloads (mime + base64) into the neutral
  # content parts the turn runner expects. Fail loud on a malformed payload.
  defp decode_images(images) when is_list(images) do
    images
    |> Enum.reduce_while({:ok, []}, fn image, {:ok, acc} ->
      with mime when is_binary(mime) <- Map.get(image, "mime_type"),
           b64 when is_binary(b64) <- Map.get(image, "data_base64"),
           {:ok, data} <- Base.decode64(b64) do
        {:cont, {:ok, [%{type: :image, mime_type: mime, data: data} | acc]}}
      else
        _ -> {:halt, {:error, :invalid_image_payload}}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      other -> other
    end
  end

  defp decode_images(_images), do: {:ok, []}

  defp cli_bridge_reply(content, opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    case cli_channel_bridge().dispatch_input_sync(content, opts) do
      {:ok, %{response: response, session_id: session_id}} ->
        %{status: "ok", response: response, session_id: session_id}

      {:error, reason} ->
        %{
          status: "error",
          error: reason_to_string(reason),
          session_id: session_id
        }
    end
  end

  defp cli_channel_bridge,
    do: Application.get_env(:fermix_core, :cli_channel_bridge, default_cli_channel_bridge())

  defp default_cli_channel_bridge do
    Module.concat(["FermixChannels", "CLI"])
  end

  defp normalize_session_id(nil), do: "cli"

  defp normalize_session_id(session_id) do
    session_id = session_id |> to_string() |> String.trim()
    if session_id == "", do: "cli", else: session_id
  end

  defp normalize_timeout_ms(timeout_ms, _default_timeout_ms)
       when is_integer(timeout_ms) and timeout_ms >= 0 do
    timeout_ms
  end

  defp normalize_timeout_ms(_timeout_ms, default_timeout_ms), do: default_timeout_ms

  defp validate_skill_name(name) do
    if String.match?(name, @skill_name_pattern) do
      :ok
    else
      {:error, :invalid_skill_name}
    end
  end

  defp skill_snapshot(snapshot) do
    %{
      version: Map.get(snapshot, :version),
      count: length(Map.get(snapshot, :skills, [])),
      skills: snapshot |> Map.get(:skills, []) |> Enum.map(&skill_summary/1),
      errors: snapshot |> Map.get(:errors, []) |> Enum.map(&inspect/1)
    }
  end

  defp skill_summary(skill) do
    %{
      name: skill.name,
      description: skill.description,
      trust: Atom.to_string(skill.trust || :operator),
      source_path: skill.source_path,
      model: skill.model,
      allowed_tools: skill.allowed_tools,
      capabilities: skill.capabilities,
      max_iterations: skill.max_iterations,
      timeout_seconds: skill.timeout_seconds
    }
  end

  defp skill_detail(skill) do
    skill
    |> skill_summary()
    |> Map.put(:body, skill.system_prompt)
  end

  defp reload_summary(summary) do
    %{
      version: Map.get(summary, :version),
      count: length(Map.get(summary, :names, [])),
      names: Map.get(summary, :names, []),
      added: Map.get(summary, :added, []),
      removed: Map.get(summary, :removed, []),
      changed: Map.get(summary, :changed, []),
      errors: summary |> Map.get(:errors, []) |> Enum.map(&inspect/1)
    }
  end

  defp safe_daemon_call(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  catch
    :exit, reason -> {:error, reason}
  end

  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string(reason) when is_binary(reason), do: reason
  defp reason_to_string(reason), do: inspect(reason)

  defp daemon_snapshot(state) do
    %{
      status: :running,
      version: to_string(Application.spec(:fermix_core, :vsn) || "unknown"),
      uptime_ms: System.monotonic_time(:millisecond) - state.started_at_ms,
      pid: System.pid()
    }
  end

  defp maybe_finalize(%{status: "shutting_down"}) do
    spawn(fn ->
      Process.sleep(150)
      :init.stop()
    end)
  end

  defp maybe_finalize(_), do: :ok

  defp default_socket_path do
    fermix_home = System.get_env("FERMIX_HOME") || Path.join(System.user_home!(), ".fermix")
    Path.join(fermix_home, "daemon.sock")
  end
end
