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
  @recv_idle_ms 50
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
         active_clients: 0,
         # Audit F-12 follow-up: track each handler's monitor ref so a
         # crash inside `do_client_loop/1` decrements the counter the
         # same way a clean exit does. Without this, a `:ok = send_event`
         # match failure would leak the increment until restart.
         client_refs: %{}
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:active_clients, _from, state) do
    {:reply, state.active_clients, state}
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

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.client_refs, ref) do
      {nil, _refs} ->
        {:noreply, state}

      {true, refs} ->
        {:noreply, %{state | client_refs: refs, active_clients: max(0, state.active_clients - 1)}}
    end
  end

  @impl true
  def handle_cast({:client_delta, delta}, state) do
    {:noreply, %{state | active_clients: max(0, state.active_clients + delta)}}
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

  defp spawn_client_handler(conn, %{active_clients: active, max_clients: max} = state)
       when active >= max do
    Logger.warning(
      "Realtime voice socket rejecting client: cap=#{max} reached (active=#{active})"
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
      session_module: state.session_module,
      session_starter: state.session_starter,
      session_opts: state.session_opts,
      session_supervisor: state.session_supervisor,
      buffer: "",
      hello_received: false
    }

    case Task.Supervisor.start_child(state.task_supervisor, fn -> client_loop(handler_state) end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        %{
          state
          | active_clients: state.active_clients + 1,
            client_refs: Map.put(state.client_refs, ref, true)
        }

      {:error, reason} ->
        Logger.warning("Realtime voice socket client handler failed to start: #{inspect(reason)}")
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

  defp client_loop(state) do
    state
    |> do_client_loop()
    |> cleanup_client()
  end

  defp do_client_loop(state) do
    state = drain_companion_events(state)

    case :gen_tcp.recv(state.conn, 0, @recv_idle_ms) do
      {:ok, bytes} ->
        case handle_bytes(bytes, state) do
          {:cont, state} -> do_client_loop(state)
          {:stop, state} -> state
        end

      {:error, :timeout} ->
        do_client_loop(state)

      {:error, :closed} ->
        state

      {:error, reason} ->
        Logger.warning("Realtime voice socket client recv error: #{inspect(reason)}")
        state
    end
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

  defp drain_companion_events(state) do
    receive do
      {:realtime, event} ->
        _ = send_event(state.conn, event)
        drain_companion_events(state)
    after
      0 -> state
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

  defp dispatch_event(%{type: "call_stop"}, state) do
    close_session(state)

    _ = send_event(state.conn, %{type: "state", state: "idle"})
    {:cont, %{state | session: nil}}
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

        # A failed write must stop the loop so cleanup_client/1 closes the
        # accepted socket. A hard `:ok =` here would raise past cleanup and
        # leak the parent-owned fd on a peer that broke mid-handshake.
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

    case state.session_starter.(opts) do
      {:ok, session} -> {:ok, session, %{state | session: session}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_session(%{session: session} = state) when is_pid(session),
    do: {:ok, session, state}

  defp require_session(_state), do: {:error, :not_connected}

  defp send_error_and_stop(reason, state) do
    _ = send_event(state.conn, %{type: "error", reason: reason_to_string(reason)})
    {:stop, state}
  end

  defp cleanup_client(state) do
    # Audit F-12 follow-up: the decrement is now driven by the parent's
    # `Process.monitor`-issued `:DOWN` message in
    # `handle_info({:DOWN, ...}, state)`, which fires regardless of how
    # the handler task exited. We no longer cast `{:client_delta, -1}`
    # here — that path missed crashes and could double-decrement once a
    # crash path was added.
    close_session(state)
    :gen_tcp.close(state.conn)
  end

  defp close_session(%{session: session, session_module: session_module})
       when is_pid(session) do
    _ = session_module.call_stop(session)

    if session_module == SessionServer and Process.alive?(session) do
      _ = GenServer.stop(session, :normal, 1_000)
    end

    :ok
  end

  defp close_session(_state), do: :ok

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
