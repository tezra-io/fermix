defmodule Fermix.CLI.Daemon do
  @moduledoc """
  Control-socket listener for `fermix status` and `fermix stop`.

  Listens on a Unix domain socket at `~/.fermix/daemon.sock` (user
  scope) or `/var/run/fermix.sock` (system scope) and serves a tiny
  4-byte-length-prefixed JSON request/response protocol. Two methods:

      {"method":"status"}    -> {"status":"ok","version":"...","uptime_ms":N}
      {"method":"shutdown"}  -> {"status":"shutting_down"}  then :init.stop()

  Started only inside `fermix run` (the supervision tree branches on
  `:fermix_core, :daemon_socket_enabled`). Stale sockets from prior
  crashes are removed on boot; double-binding fails fast on
  EADDRINUSE rather than silently overwriting.
  """

  use GenServer

  alias FermixCore.Agents.MainAgent
  alias FermixCore.Agents.SkillRegistry
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

    File.mkdir_p!(Path.dirname(socket_path))

    case clear_stale_socket(socket_path) do
      :ok -> do_listen(socket_path, task_supervisor, plugins_runtime)
      {:error, reason} -> {:stop, reason}
    end
  end

  defp do_listen(socket_path, task_supervisor, plugins_runtime) do
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
    Task.Supervisor.start_child(sup, fn -> handle_connection(conn, state) end)
  end

  defp handle_connection(conn, state) do
    case :gen_tcp.recv(conn, 0, @recv_timeout_ms) do
      {:ok, line} ->
        response = handle_request(String.trim(line), state)
        :gen_tcp.send(conn, Jason.encode!(response))
        maybe_finalize(response)

      {:error, _reason} ->
        :ok
    end
  after
    :gen_tcp.close(conn)
  end

  defp handle_request(line, state) do
    # The local control socket has no per-request auth; the trust boundary is
    # the 0600 socket file under FERMIX_HOME. `agent_message` is a deliberate
    # operator action from `fermix ask`, and can trigger LLM/tool work.
    case Jason.decode(line) do
      {:ok, %{"method" => method} = request} ->
        handle_method(method, request, state)

      _ ->
        %{status: "error", reason: "invalid request"}
    end
  end

  defp handle_method("status", _request, state), do: status_reply(state)
  defp handle_method("overview", _request, state), do: overview_reply(state)
  defp handle_method("health", _request, _state), do: health_reply()
  defp handle_method("agents", _request, _state), do: agents_reply()
  defp handle_method("capabilities", request, _state), do: capabilities_reply(request)
  defp handle_method("skills_list", _request, _state), do: skills_list_reply()
  defp handle_method("skills_view", request, _state), do: skills_view_reply(request)
  defp handle_method("skills_reload", _request, _state), do: skills_reload_reply()
  defp handle_method("plugins_apply", _request, state), do: plugins_apply_reply(state)
  defp handle_method("agent_message", request, _state), do: agent_message_reply(request)
  defp handle_method("observability", _request, _state), do: observability_reply()

  defp handle_method("shutdown", _request, _state) do
    Trace.record(:agent_event, "daemon", %{event: "shutdown_requested"})
    %{status: "shutting_down"}
  end

  defp handle_method(method, _request, _state) do
    %{status: "error", reason: "unknown method", method: method}
  end

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
