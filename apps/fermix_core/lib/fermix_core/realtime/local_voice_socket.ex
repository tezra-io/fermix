defmodule FermixCore.Realtime.LocalVoiceSocket do
  @moduledoc """
  Local Unix-domain socket listener for the native Realtime voice companion.
  """

  use GenServer

  alias FermixCore.Config, as: CoreConfig
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.DeviceIdentity
  alias FermixCore.Realtime.Protocol
  alias FermixCore.Realtime.SessionServer
  alias FermixCore.Realtime.SessionSupervisor
  alias FermixCore.Setup.ConfigStore

  require Logger

  @accept_idle_ms 50
  @max_wire_line_bytes 65_536
  @default_max_clients 4

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec active_clients(GenServer.server()) :: {:ok, non_neg_integer()} | {:error, term()}
  def active_clients(server \\ __MODULE__) do
    {:ok, GenServer.call(server, :active_clients)}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  @impl true
  def init(opts) do
    socket_path = Keyword.get(opts, :socket_path, Config.socket_path())
    File.mkdir_p!(Path.dirname(socket_path))

    with :ok <- clear_stale_socket(socket_path),
         {:ok, listen_socket} <- listen(socket_path) do
      File.chmod!(socket_path, 0o600)
      Process.send_after(self(), :accept, 0)

      {:ok,
       %{
         listen_socket: listen_socket,
         socket_path: socket_path,
         task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
         session_supervisor: Keyword.get(opts, :session_supervisor, SessionSupervisor),
         session_starter: Keyword.get(opts, :session_starter, &default_session_starter/1),
         session_module: Keyword.get(opts, :session_module, SessionServer),
         session_opts: Keyword.get(opts, :session_opts, []),
         max_clients: positive_int_opt(opts, :max_clients, @default_max_clients),
         # handler pid -> bound session pid (or nil before `call_start`). This map
         # IS both the client count (its size) and the crash-safe teardown ledger:
         # on a handler's monitored :DOWN we drop the entry (the decrement) and
         # tear its session down. The accepted socket is handed to the handler via
         # `controlling_process`, so the fd closes with the handler on every exit.
         clients: %{}
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:active_clients, _from, state) do
    {:reply, map_size(state.clients), state}
  end

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.listen_socket, @accept_idle_ms) do
      {:ok, conn} ->
        state = spawn_client_handler(conn, state)
        send(self(), :accept)
        {:noreply, state}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, :closed} ->
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.warning("Realtime voice socket accept error: #{inspect(reason)}")
        Process.send_after(self(), :accept, 1_000)
        {:noreply, state}
    end
  end

  # A handler exited (clean stop, crash, or kill). Its owned socket is already
  # closed by the runtime; here we drop it from `clients` (the count decrement)
  # and tear down whatever session it still had bound. This is the single,
  # crash-safe teardown path — it fires on EVERY handler exit, which the
  # handler's own immutable loop state could not guarantee on a crash.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Map.has_key?(state.clients, pid) do
      false ->
        {:noreply, state}

      true ->
        {session, clients} = Map.pop(state.clients, pid)
        schedule_session_teardown(session, state)
        {:noreply, %{state | clients: clients}}
    end
  end

  @impl true
  def handle_cast({:bind_session, pid, session}, state) do
    {:noreply, %{state | clients: rebind(state.clients, pid, session)}}
  end

  def handle_cast({:unbind_session, pid}, state) do
    {:noreply, %{state | clients: rebind(state.clients, pid, nil)}}
  end

  defp rebind(clients, pid, value) do
    if Map.has_key?(clients, pid), do: Map.put(clients, pid, value), else: clients
  end

  @impl true
  def terminate(_reason, state) do
    _ = :gen_tcp.close(state.listen_socket)
    _ = File.rm(state.socket_path)
    :ok
  end

  defp listen(socket_path) do
    :gen_tcp.listen(0, [
      :binary,
      {:active, false},
      {:ifaddr, {:local, socket_path}},
      {:reuseaddr, true}
    ])
  end

  # If the socket file exists, probe it before deleting. A live listener
  # answers; a stale file from a previous crash refuses or errors. Unlinking
  # a live socket would let us bind the same path while the original keeps
  # serving clients but is no longer reachable at it. Same discipline as the
  # daemon control socket (`Fermix.CLI.Daemon`).
  defp clear_stale_socket(socket_path) do
    cond do
      not File.exists?(socket_path) -> :ok
      live_socket?(socket_path) -> {:error, {:another_voice_socket_running, socket_path}}
      true -> rm_stale(socket_path)
    end
  end

  defp live_socket?(socket_path) do
    case :gen_tcp.connect({:local, to_charlist(socket_path)}, 0, [:binary, {:active, false}], 500) do
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

  defp spawn_client_handler(conn, %{clients: clients, max_clients: max} = state)
       when map_size(clients) >= max do
    Logger.warning(
      "Realtime voice socket rejecting client: cap=#{max} reached (active=#{map_size(clients)})"
    )

    _ = send_event(conn, %{type: "error", reason: "max_clients_reached"})
    _ = :gen_tcp.close(conn)
    state
  end

  defp spawn_client_handler(conn, state) do
    handler_state = %{
      parent: self(),
      conn: conn,
      config: Config.current(),
      session: nil,
      session_ref: nil,
      task_supervisor: state.task_supervisor,
      session_module: state.session_module,
      session_starter: state.session_starter,
      session_opts: state.session_opts,
      session_supervisor: state.session_supervisor,
      buffer: "",
      hello_received: false
    }

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           await_handover(handler_state)
         end) do
      {:ok, pid} ->
        _ref = Process.monitor(pid)
        hand_over_socket(conn, pid, state)

      {:error, reason} ->
        Logger.warning("Realtime voice socket client handler failed to start: #{inspect(reason)}")
        _ = :gen_tcp.close(conn)
        state
    end
  end

  # Transfer ownership of the accepted socket to its handler so the fd is closed
  # the instant that handler exits — crash, kill, or clean stop. Before this the
  # listener kept the fd open behind a dead reader task and the peer never saw
  # EOF (the root-cause leak). The socket is passive here, so nothing is lost in
  # the handoff; the handler arms active mode only after it receives the signal.
  defp hand_over_socket(conn, pid, state) do
    case :gen_tcp.controlling_process(conn, pid) do
      :ok ->
        send(pid, :socket_handover)
        %{state | clients: Map.put(state.clients, pid, nil)}

      {:error, reason} ->
        Logger.warning("Realtime voice socket controlling_process failed: #{inspect(reason)}")
        send(pid, :handover_failed)
        _ = :gen_tcp.close(conn)
        state
    end
  end

  defp positive_int_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 ->
        value

      other ->
        raise ArgumentError,
              "#{inspect(key)} must be a positive integer, got: #{inspect(other)}"
    end
  end

  # The handler waits to own the socket before touching it. Once ownership lands
  # it arms active mode and enters the unified loop; a failed handoff just exits.
  defp await_handover(%{conn: conn} = state) do
    receive do
      :socket_handover -> arm_and_loop(conn, state)
      :handover_failed -> :ok
    after
      # Bound the wait: if the listener dies between start_child and the handover
      # signal, neither message ever arrives. Time out and exit (no session is
      # bound yet, so nothing to tear down) rather than block a task forever.
      5_000 ->
        Logger.debug("Realtime voice socket handler timed out awaiting socket handover")
        :ok
    end
  end

  defp arm_and_loop(conn, state) do
    case :inet.setopts(conn, [{:active, :once}]) do
      :ok ->
        client_loop(state)

      {:error, reason} ->
        Logger.debug("Realtime voice socket failed to arm client socket: #{inspect(reason)}")
        :ok
    end
  end

  # One unified receive loop now that the handler owns the socket in active mode:
  # inbound bytes, peer close/error, monitored session death, and companion
  # pushes all land here — no recv-poll latency and no companion-drain kludge.
  # A normal terminal branch funnels through `stop_and_exit/1` (own-session
  # teardown) before the handler exits, closing the owned socket (peer EOF) and
  # firing the listener's monitor, which decrements the count and reaps any
  # session the handler could not (only a handler CRASH leaves that to the
  # listener).
  defp client_loop(state) do
    receive do
      {:tcp, conn, bytes} when conn == state.conn ->
        handle_tcp_bytes(bytes, state)

      {:tcp_closed, conn} when conn == state.conn ->
        stop_and_exit(state)

      {:tcp_error, conn, reason} when conn == state.conn ->
        Logger.warning("Realtime voice socket client recv error: #{inspect(reason)}")
        stop_and_exit(state)

      {:realtime, event} ->
        _ = send_event(state.conn, event)
        client_loop(state)

      {:DOWN, ref, :process, _pid, reason} when ref == state.session_ref ->
        handle_session_down(reason, state)
    end
  end

  defp handle_tcp_bytes(bytes, state) do
    case handle_bytes(bytes, state) do
      {:cont, state} -> rearm_or_stop(state)
      {:stop, state} -> stop_and_exit(state)
    end
  end

  defp rearm_or_stop(state) do
    case :inet.setopts(state.conn, [{:active, :once}]) do
      :ok ->
        client_loop(state)

      {:error, reason} ->
        Logger.debug("Realtime voice socket failed to re-arm client socket: #{inspect(reason)}")
        stop_and_exit(state)
    end
  end

  # A normal terminal return funnels here so the handler tears down its OWN bound
  # session before exiting: a live (billed) OpenAI WebSocket must never outlive
  # the connection, even when the listener — whose monitor is the crash-path
  # teardown — has itself crashed and can no longer react to this handler's
  # :DOWN. A handler CRASH cannot run this; that path stays the listener's.
  defp stop_and_exit(state) do
    _ = reset_session(state)
    :ok
  end

  # The session died mid-call. Tell the peer (best effort), then return so the
  # handler exits and the socket closes. Without this, the audio_chunk cast would
  # keep "succeeding" into a dead session while the peer waited on silence.
  defp handle_session_down(reason, state) do
    _ =
      send_event(state.conn, %{type: "error", reason: reason_to_string({:session_down, reason})})

    :ok
  end

  defp handle_bytes(bytes, state) do
    state
    |> Map.update!(:buffer, &(&1 <> bytes))
    |> drain_client_lines()
  end

  defp drain_client_lines(%{buffer: buffer} = state) do
    case :binary.match(buffer, "\n") do
      {newline, 1} ->
        <<line::binary-size(newline), _newline::binary-size(1), rest::binary>> = buffer
        process_one_line(line, %{state | buffer: rest})

      :nomatch when byte_size(buffer) > @max_wire_line_bytes ->
        send_error_and_stop(:line_too_large, state)

      :nomatch ->
        {:cont, state}
    end
  end

  defp process_one_line("", state), do: drain_client_lines(state)

  defp process_one_line(line, state) do
    case handle_line(String.trim(line), state) do
      {:cont, state} -> drain_client_lines(state)
      {:stop, state} -> {:stop, state}
    end
  end

  defp handle_line(line, state) do
    case Protocol.decode_client_event(line, state.config) do
      {:ok, event} -> dispatch_event(event, state)
      {:error, reason} -> send_error_and_stop(reason, state)
    end
  end

  defp dispatch_event(%{type: "client_hello", payload: payload}, state) do
    handle_client_hello(payload, state)
  end

  # Every other event is gated behind a completed handshake. Placed after the
  # `client_hello` clause and before the per-event clauses, this catches any
  # premature event while `hello_received` is false; once the handshake lands,
  # it no longer matches and the specific handlers below run.
  defp dispatch_event(_event, %{hello_received: false} = state) do
    send_error_and_stop(:handshake_required, state)
  end

  defp dispatch_event(%{type: "call_start"}, state) do
    case ensure_session(state) do
      {:ok, session, state} ->
        with :ok <- state.session_module.call_start(session) do
          {:cont, state}
        else
          {:error, reason} -> send_error_and_stop(reason, state)
        end

      {:error, reason} ->
        send_error_and_stop(reason, state)
    end
  end

  defp dispatch_event(%{type: "audio_chunk", payload: %{"audio" => audio}}, state) do
    case require_session(state) do
      {:ok, session, state} ->
        with :ok <- state.session_module.audio_chunk(session, audio) do
          {:cont, state}
        else
          {:error, reason} -> send_error_and_stop(reason, state)
        end

      {:error, reason} ->
        send_error_and_stop(reason, state)
    end
  end

  defp dispatch_event(%{type: "interrupt", payload: payload}, state) do
    audio_end_ms = Map.get(payload, "audio_end_ms")

    case require_session(state) do
      {:ok, session, state} ->
        with :ok <- state.session_module.interrupt(session, audio_end_ms) do
          {:cont, state}
        else
          {:error, reason} -> send_error_and_stop(reason, state)
        end

      {:error, reason} ->
        send_error_and_stop(reason, state)
    end
  end

  defp dispatch_event(%{type: "mute", payload: payload}, state) do
    enabled? = Map.get(payload, "enabled", true) == true

    case require_session(state) do
      {:ok, session, state} ->
        with :ok <- state.session_module.mute(session, enabled?) do
          {:cont, state}
        else
          {:error, reason} -> send_error_and_stop(reason, state)
        end

      {:error, reason} ->
        send_error_and_stop(reason, state)
    end
  end

  # `call_stop` ends the CALL but keeps the CONNECTION open for a fresh one, so
  # the handler tears the session down itself and unbinds it from the listener
  # (distinct from connection loss, which the listener's monitor handles).
  defp dispatch_event(%{type: "call_stop"}, state) do
    state = reset_session(state)
    _ = send_event(state.conn, %{type: "state", state: "idle"})
    {:cont, state}
  end

  # A repeat hello is a protocol violation — the handshake is a one-shot
  # transition. Fail loud rather than silently re-negotiating.
  defp handle_client_hello(_payload, %{hello_received: true} = state) do
    send_error_and_stop(:unexpected_client_hello, state)
  end

  defp handle_client_hello(%{"protocol_version" => version}, state) do
    case Protocol.negotiate(version) do
      :ok ->
        {min, max} = Protocol.supported_version_range()
        reply = %{type: "server_hello", min_version: min, max_version: max}

        # A peer that broke mid-handshake is expected, not a bug: stop the loop
        # so the handler exits cleanly and its owned socket closes (peer EOF),
        # instead of letting a hard `:ok =` match-fail turn a normal disconnect
        # into a handler crash.
        case send_event(state.conn, reply) do
          :ok -> {:cont, %{state | hello_received: true}}
          {:error, _reason} -> {:stop, state}
        end

      {:error, direction} ->
        send_version_mismatch_and_stop(direction, version, state)
    end
  end

  defp send_version_mismatch_and_stop(direction, client_version, state) do
    {min, max} = Protocol.supported_version_range()

    _ =
      send_event(state.conn, %{
        type: "error",
        reason: "unsupported_protocol_version",
        direction: Atom.to_string(direction),
        client_version: client_version,
        min_version: min,
        max_version: max
      })

    {:stop, state}
  end

  defp ensure_session(%{session: session} = state) when is_pid(session), do: {:ok, session, state}

  defp ensure_session(state) do
    opts =
      state.session_opts
      |> Keyword.put(:companion, self())
      |> Keyword.put(:session_supervisor, state.session_supervisor)
      |> Keyword.put_new(:task_supervisor, state.task_supervisor)

    case state.session_starter.(opts) do
      {:ok, session} -> {:ok, session, bind_session(state, session)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Monitor the session so its death reaches the loop (`handle_session_down`),
  # and register it with the listener so the listener's handler-:DOWN tears it
  # down on ANY handler exit — the crash-safe path the immutable loop state
  # cannot provide. The bind is guaranteed to reach the listener before the
  # handler's :DOWN (monitor ordering), so there is no teardown gap on a crash.
  defp bind_session(state, session) do
    ref = Process.monitor(session)
    GenServer.cast(state.parent, {:bind_session, self(), session})
    %{state | session: session, session_ref: ref}
  end

  defp reset_session(%{session: session} = state) when is_pid(session) do
    if is_reference(state.session_ref), do: Process.demonitor(state.session_ref, [:flush])
    stop_session(session, state.session_module)
    GenServer.cast(state.parent, {:unbind_session, self()})
    %{state | session: nil, session_ref: nil}
  end

  defp reset_session(state), do: state

  defp require_session(%{session: session} = state) when is_pid(session),
    do: {:ok, session, state}

  defp require_session(_state), do: {:error, :not_connected}

  defp send_error_and_stop(reason, state) do
    _ = send_event(state.conn, %{type: "error", reason: reason_to_string(reason)})
    {:stop, state}
  end

  # Run session teardown OFF the listener's :DOWN handler in a throwaway task so
  # a slow `GenServer.stop` never blocks the listener from accepting new clients.
  defp schedule_session_teardown(nil, _state), do: :ok

  defp schedule_session_teardown(session, state) when is_pid(session) do
    module = state.session_module

    _ =
      Task.Supervisor.start_child(state.task_supervisor, fn -> stop_session(session, module) end)

    :ok
  end

  # Best-effort graceful teardown shared by the listener's crash path and the
  # handler's own terminal exits. Exit-safe: it may race a session already dying
  # on its own, so a call_stop/stop that exits must not take down the caller
  # (listener or handler). Only a real SessionServer is GenServer.stop-ed; a test
  # session double just gets call_stop.
  defp stop_session(session, session_module) when is_pid(session) do
    if Process.alive?(session) do
      session_module.call_stop(session)

      if session_module == SessionServer and Process.alive?(session) do
        GenServer.stop(session, :normal, 1_000)
      end
    end

    :ok
  catch
    :exit, reason ->
      Logger.debug("Realtime voice socket session teardown exited: #{inspect(reason)}")
      :ok
  end

  defp send_event(conn, event) do
    with {:ok, line} <- Protocol.encode_server_event(event.type, Map.delete(event, :type)) do
      :gen_tcp.send(conn, line)
    end
  end

  defp default_session_starter(opts) do
    session_supervisor = Keyword.fetch!(opts, :session_supervisor)
    opts = Keyword.drop(opts, [:session_supervisor])

    with {:ok, session_opts} <- build_session_opts(opts) do
      SessionSupervisor.start_session(session_supervisor, session_opts)
    end
  end

  defp build_session_opts(opts) do
    with {:ok, api_key} <- CoreConfig.provider_api_key(:openai),
         {:ok, device_id} <-
           DeviceIdentity.ensure_device_id(ConfigStore.workspace_paths().realtime) do
      owner_id = MemoryConfig.owner_id()

      {:ok,
       opts
       |> Keyword.put(:config, Config.current())
       |> Keyword.put(:api_key, api_key)
       |> Keyword.put(:device_id, device_id)
       |> Keyword.put_new(:session_scope, session_scope())
       |> Keyword.put(:safety_identifier, DeviceIdentity.safety_identifier(owner_id, device_id))}
    end
  end

  defp session_scope do
    "session:" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string(reason) when is_binary(reason), do: reason
  defp reason_to_string(reason), do: inspect(reason)
end
