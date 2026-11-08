defmodule FermixCore.Realtime.LocalVoiceSocket do
  @moduledoc """
  The Unix adapter for the Mac app's voice calls: the `realtime.sock`
  listener.

  It owns what is the Unix wire's: the listener and its peer gate, the client
  cap, newline-delimited JSON framing, and the `client_hello`/`server_hello`
  handshake. Every call of a connection is the `desktop` endpoint's, and once
  the handshake lands the connection's call half is a `CallClient`, which owns
  the call itself (the engine's minimum version, the session, the command
  verbs, the flush before a refusal, teardown): decode, `CallClient`, encode.
  A connection's session is started by `SessionGuard` for the connection's
  handler, which tears it down on any exit of that handler, even mid-start.
  """

  use GenServer

  alias FermixCore.Realtime.CallClient
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.Protocol
  alias FermixCore.SocketPath
  alias FermixCore.SocketPeer

  require Logger

  @accept_retry_ms 1_000
  @max_wire_line_bytes 65_536
  @default_max_clients 4
  # What a connection's `CallClient` is built from besides the handshake. The
  # socket's own `session_opts` become the client's `starter_opts`.
  @client_opts [:session_module, :session_starter, :session_supervisor, :session_guard]

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
    Process.flag(:trap_exit, true)
    socket_path = Keyword.get(opts, :socket_path, Config.socket_path())

    with :ok <- check_socket_path(socket_path),
         :ok <- ensure_socket_dir(socket_path),
         :ok <- clear_stale_socket(socket_path),
         {:ok, listen_socket} <- listen(socket_path) do
      File.chmod!(socket_path, 0o600)
      task_supervisor = Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor)

      {:ok,
       %{
         listen_socket: listen_socket,
         socket_path: socket_path,
         task_supervisor: task_supervisor,
         client_opts:
           [task_supervisor: task_supervisor, starter_opts: Keyword.get(opts, :session_opts, [])] ++
             Keyword.take(opts, @client_opts),
         # Whether this socket answers a peer at all (`SocketPeer.admit/2`).
         peer_gate: Keyword.get(opts, :peer_gate, &SocketPeer.admit/1),
         max_clients: positive_int_opt(opts, :max_clients, @default_max_clients),
         # handler pid -> its monitor. The map's size is the client count: a
         # handler's :DOWN drops its entry. The accepted socket is handed to the
         # handler via `controlling_process`, so the fd closes with the handler on
         # every exit, and its session is `SessionGuard`'s to tear down.
         clients: %{}
       }, {:continue, :accept}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:active_clients, _from, state) do
    {:reply, map_size(state.clients), state}
  end

  # Connections are accepted by a linked process of the socket's own, so the
  # socket answers a call (`active_clients/1`, which Health reads) the moment it
  # comes, never once an accept's wait ends. The clients and their cap are this
  # server's state, so the acceptor hands each connection here to be admitted.
  @impl true
  def handle_continue(:accept, state) do
    server = self()
    acceptor = spawn_link(fn -> accept_loop(state.listen_socket, server) end)
    {:noreply, Map.put(state, :acceptor, acceptor)}
  end

  @impl true
  def handle_info({:accepted, conn}, state), do: {:noreply, serve_admitted(conn, state)}

  # The acceptor ends once the listening socket closed, or by a crash; the
  # socket ends with it.
  def handle_info({:EXIT, acceptor, reason}, %{acceptor: acceptor} = state),
    do: {:stop, reason, state}

  # A handler exited (clean stop, crash, or kill). Its owned socket is already
  # closed by the runtime and its session is the guard's; here it only stops
  # counting.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | clients: Map.delete(state.clients, pid)}}
  end

  @impl true
  def terminate(_reason, state) do
    close_result = :gen_tcp.close(state.listen_socket)
    unlink_result = unlink_socket(state.socket_path)
    report_cleanup(close_result, unlink_result)
  end

  defp unlink_socket(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp report_cleanup(:ok, :ok), do: :ok

  defp report_cleanup(close_result, unlink_result) do
    Logger.error(
      "Realtime socket cleanup failed: " <>
        "listener_close=#{inspect(close_result)} socket_unlink=#{inspect(unlink_result)}"
    )

    :ok
  end

  # Before `mkdir_p` and before bind: an over-long address fails the bind with a
  # bare `:einval`, which reads as a Fermix bug instead of as an over-long home.
  # The pre-flight measures the path string and touches no filesystem object.
  defp check_socket_path(socket_path) do
    case SocketPath.check(socket_path) do
      :ok ->
        :ok

      {:error, {:path_too_long, bytes, limit}} ->
        Logger.error(
          "Realtime voice socket refused: " <>
            SocketPath.refusal("realtime.sock", bytes, limit) <> ". Path: #{socket_path}"
        )

        {:error, {:socket_path_too_long, bytes, limit, socket_path}}
    end
  end

  defp ensure_socket_dir(socket_path) do
    File.mkdir_p!(Path.dirname(socket_path))
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

  defp accept_loop(listen_socket, server) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, conn} ->
        :ok = hand_to_server(conn, server)
        accept_loop(listen_socket, server)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("Realtime voice socket accept error: #{inspect(reason)}")
        Process.sleep(@accept_retry_ms)
        accept_loop(listen_socket, server)
    end
  end

  # The accepted socket is passive, so nothing is lost in the handover; a
  # server that is gone takes the acceptor with it through the link.
  defp hand_to_server(conn, server) do
    case :gen_tcp.controlling_process(conn, server) do
      :ok ->
        send(server, {:accepted, conn})
        :ok

      {:error, reason} ->
        Logger.warning("Realtime voice socket could not take a connection: #{inspect(reason)}")
        _ = :gen_tcp.close(conn)
        :ok
    end
  end

  # A command Fermix confines gets no answer here: no session, no bill, no
  # audio taken as the operator's voice.
  defp serve_admitted(conn, state) do
    case state.peer_gate.(conn) do
      :ok ->
        spawn_client_handler(conn, state)

      {:error, reason} ->
        :ok = SocketPeer.refuse(conn, state.socket_path, reason)
        state
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
      conn: conn,
      config: Config.current(),
      client_opts: state.client_opts,
      buffer: "",
      # The connection's `CallClient`, built when the handshake lands; every
      # event but `client_hello` is gated on it.
      client: nil
    }

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           await_handover(handler_state)
         end) do
      {:ok, pid} ->
        hand_over_socket(conn, pid, Process.monitor(pid), state)

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
  defp hand_over_socket(conn, pid, ref, state) do
    case :gen_tcp.controlling_process(conn, pid) do
      :ok ->
        send(pid, :socket_handover)
        %{state | clients: Map.put(state.clients, pid, ref)}

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
  # firing the listener's monitor, which decrements the count. Only a handler
  # CRASH leaves the session to `SessionGuard`.
  defp client_loop(state) do
    session_ref = session_ref(state.client)

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

      {:DOWN, ^session_ref, :process, _pid, reason} ->
        handle_session_down(reason, state)
    end
  end

  # Nil before a session is bound: no `:DOWN` carries it.
  defp session_ref(nil), do: nil
  defp session_ref(%CallClient{session_ref: ref}), do: ref

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
  # session before exiting: a live (billed) provider socket must never outlive
  # the connection, even when the guard could no longer react to this
  # handler's exit. A handler CRASH cannot run this; that path is the guard's.
  defp stop_and_exit(%{client: nil}), do: :ok

  defp stop_and_exit(%{client: client}) do
    _client = CallClient.teardown(client)
    :ok
  end

  # The session died mid-call. The peer is told, then the handler exits and the
  # socket closes. Without this, the audio_chunk cast would keep "succeeding"
  # into a dead session while the peer waited on silence.
  defp handle_session_down(reason, state) do
    {:stop, _client} = CallClient.session_down(state.client, reason)
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
  # `client_hello` clause and before the call's, this catches any premature
  # event while the connection has no `CallClient` yet.
  defp dispatch_event(_event, %{client: nil} = state) do
    send_error_and_stop(:handshake_required, state)
  end

  defp dispatch_event(event, state) do
    {verdict, client} = CallClient.event(state.client, event)
    {verdict, %{state | client: client}}
  end

  # A repeat hello is a protocol violation — the handshake is a one-shot
  # transition. Fail loud rather than silently re-negotiating.
  defp handle_client_hello(_payload, %{client: %CallClient{}} = state) do
    send_error_and_stop(:unexpected_client_hello, state)
  end

  defp handle_client_hello(%{"protocol_version" => version}, state) do
    case Protocol.hello_reply(version) do
      # A peer that broke mid-handshake is expected, not a bug: stop the loop
      # so the handler exits cleanly and its owned socket closes (peer EOF),
      # instead of letting a hard `:ok =` match-fail turn a normal disconnect
      # into a handler crash.
      {:ok, reply} ->
        case send_event(state.conn, reply) do
          :ok -> {:cont, %{state | client: new_client(state, version)}}
          {:error, _reason} -> {:stop, state}
        end

      {:error, refusal} ->
        _ = send_event(state.conn, refusal)
        {:stop, state}
    end
  end

  # Every call on this socket is the Mac app's: the `desktop` endpoint, at the
  # version the handshake negotiated.
  defp new_client(state, version) do
    conn = state.conn

    state.client_opts
    |> Keyword.merge(
      endpoint: :desktop,
      protocol_version: version,
      config: state.config,
      emit: fn event -> send_event(conn, event) end
    )
    |> CallClient.new()
  end

  defp send_error_and_stop(reason, state) do
    _ = send_event(state.conn, CallClient.error_frame(reason))
    {:stop, state}
  end

  defp send_event(conn, event) do
    with {:ok, line} <- Protocol.encode_server_event(event.type, Map.delete(event, :type)) do
      :gen_tcp.send(conn, line)
    end
  end
end
