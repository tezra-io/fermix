defmodule FermixCore.Browser.Bridge.Endpoint do
  @moduledoc """
  The browser-bridge Unix-domain listener (M42 slice 7 §3).

  Binds `<FERMIX_HOME>/browser_bridge.sock` at 0600 — the same class of surface
  as the ACP socket, the realtime voice socket and the daemon control socket:
  same user, same machine, no network, no token. What connects is
  `fermix browser-bridge`, the pump Chrome starts as the extension's native
  messaging host; the frames are one JSON object each under `{packet, 4}`, so
  there is no buffer to drain and a frame past the ceiling fails with
  `:emsgsize` rather than being accumulated.

  The two protections that apply before a `Peer` exists live here: a
  **stale-socket probe** (a socket file left by a crashed daemon is unlinked, a
  live one refuses to be stolen) and the **connection cap**.

  The bridge is opt-in and optional, so a socket it cannot bind costs the bridge
  and nothing else: `init/1` logs one actionable error naming the path and the
  reason, then returns `:ignore`, and the daemon boots without it.
  """

  use GenServer

  require Logger

  alias FermixCore.Browser.Bridge.Grants
  alias FermixCore.Browser.Bridge.Peer
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.SocketPath

  # One browser at a time is the shape of the feature; the headroom is for a
  # second profile (a dev Chrome beside the daily one) and for a connection
  # whose peer has not yet been reaped.
  @max_connections 8
  @accept_idle_ms 50
  @accept_retry_ms 1_000
  @socket_name "browser_bridge.sock"
  # Screenshots and PDFs come back base64-encoded in a single frame.
  @max_frame_bytes 33_554_432

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The socket path this listener binds: `browser_bridge.sock` under `FERMIX_HOME`."
  @spec socket_path() :: String.t()
  def socket_path, do: Path.join(ConfigStore.fermix_home(), @socket_name)

  @doc "The largest frame either side may send, in bytes."
  @spec max_frame_bytes() :: pos_integer()
  def max_frame_bytes, do: @max_frame_bytes

  @doc "How many extensions are connected right now."
  @spec connection_count(GenServer.server()) :: non_neg_integer()
  def connection_count(server \\ __MODULE__), do: GenServer.call(server, :connection_count)

  @impl true
  def init(opts) do
    # Trap exits so `terminate/2` runs on a supervisor shutdown: the listen
    # socket and its socket FILE are this process's resources, and they are
    # released on every exit path.
    Process.flag(:trap_exit, true)

    path = Keyword.get(opts, :socket_path, socket_path())

    case bind(path) do
      {:ok, listen_socket} ->
        Process.send_after(self(), :accept, 0)
        Logger.info("Browser bridge listening on #{path}")
        {:ok, build_state(listen_socket, path, opts)}

      {:error, reason} ->
        Logger.error(refusal(reason, path))
        :ignore
    end
  end

  @impl true
  def handle_call(:connection_count, _from, state), do: {:reply, connections(state), state}

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.listen_socket, @accept_idle_ms) do
      {:ok, socket} ->
        accept_connection(socket, state)
        send(self(), :accept)
        {:noreply, state}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, :closed} ->
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.warning("Browser bridge accept error: #{inspect(reason)}")
        Process.send_after(self(), :accept, @accept_retry_ms)
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    _ = :gen_tcp.close(state.listen_socket)
    _ = File.rm(state.socket_path)
    :ok
  end

  defp build_state(listen_socket, path, opts) do
    %{
      listen_socket: listen_socket,
      socket_path: path,
      grants: Keyword.get(opts, :grants, Grants),
      peer_supervisor:
        Keyword.get(opts, :peer_supervisor, FermixCore.Browser.Bridge.PeerSupervisor),
      max_connections: Keyword.get(opts, :max_connections, @max_connections)
    }
  end

  # Every step that can fail on an operator's machine, in the order the OS cares
  # about. Each failure carries the stage it came from, so a bare `:eacces` says
  # which operation the kernel refused.
  defp bind(path) do
    with :ok <- SocketPath.check(path),
         :ok <- stage(:mkdir, File.mkdir_p(Path.dirname(path))),
         :ok <- clear_stale_socket(path),
         {:ok, listen_socket} <- stage(:bind, listen(path)),
         :ok <- chmod_socket(path, listen_socket) do
      {:ok, listen_socket}
    end
  end

  defp stage(_stage, :ok), do: :ok
  defp stage(_stage, {:ok, value}), do: {:ok, value}
  defp stage(stage, {:error, reason}), do: {:error, {stage, reason}}

  defp listen(path) do
    :gen_tcp.listen(0, [
      :binary,
      {:active, false},
      {:ifaddr, {:local, path}},
      {:packet, 4},
      {:packet_size, @max_frame_bytes},
      {:reuseaddr, true}
    ])
  end

  # The listen socket is this function's to own the moment the mode cannot be
  # tightened: a world-readable bridge socket is a wider surface than no bridge.
  defp chmod_socket(path, listen_socket) do
    case File.chmod(path, 0o600) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = :gen_tcp.close(listen_socket)
        _ = File.rm(path)
        {:error, {:chmod, reason}}
    end
  end

  defp refusal({:path_too_long, bytes, limit}, path) do
    "The browser bridge is off for this boot: " <>
      SocketPath.refusal("browser bridge socket", bytes, limit) <> ". Path: #{path}"
  end

  defp refusal({:another_bridge_running, _path}, path) do
    "The browser bridge is off for this boot: another daemon is already listening on #{path}. " <>
      "Stop it, or give this daemon its own FERMIX_HOME, then restart."
  end

  defp refusal({:stale_socket_unlink_failed, reason, _path}, path) do
    "The browser bridge is off for this boot: a stale socket file at #{path} could not be " <>
      "removed (#{inspect(reason)}). Delete it and restart."
  end

  defp refusal({stage, reason}, path) when reason in [:eacces, :eperm] do
    "The browser bridge is off for this boot: permission denied (#{stage}) on #{path}. " <>
      "Check the ownership and mode of #{Path.dirname(path)}, then restart."
  end

  defp refusal({stage, :eaddrinuse}, path) do
    "The browser bridge is off for this boot: the socket address #{path} is already in use " <>
      "(#{stage}). Stop whatever holds it, or delete the socket file, then restart."
  end

  defp refusal({stage, reason}, path) do
    "The browser bridge is off for this boot: the socket #{path} could not be opened — " <>
      "#{stage} failed with #{inspect(reason)}. Everything else on this daemon is running."
  end

  # Probe before unlinking. A live listener answers, and stealing its path would
  # leave it serving an extension nobody can reach again; a stale file from a
  # crashed daemon refuses and is removed. The probe speaks the same framing as
  # the socket it probes.
  defp clear_stale_socket(path) do
    cond do
      not File.exists?(path) -> :ok
      live_socket?(path) -> {:error, {:another_bridge_running, path}}
      true -> unlink_stale(path)
    end
  end

  defp live_socket?(path) do
    opts = [:binary, {:active, false}, {:packet, 4}, {:packet_size, @max_frame_bytes}]

    case :gen_tcp.connect({:local, to_charlist(path)}, 0, opts, 500) do
      {:ok, socket} ->
        _ = :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  catch
    :exit, :badarg -> false
  end

  defp unlink_stale(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:stale_socket_unlink_failed, reason, path}}
    end
  end

  # The peer supervisor's live child count IS the connection count: a Peer owns
  # its socket, so a connection exists exactly as long as its Peer does.
  defp connections(state) do
    %{active: active} = DynamicSupervisor.count_children(state.peer_supervisor)
    active
  end

  defp accept_connection(socket, state) do
    if connections(state) >= state.max_connections do
      refuse(socket, state)
    else
      start_peer(socket, state)
    end
  end

  defp refuse(socket, state) do
    Logger.warning(
      "Browser bridge refusing a connection: #{state.max_connections} connections already active"
    )

    _ = :gen_tcp.send(socket, Jason.encode!(%{type: "refused", reason: "too_many_connections"}))
    _ = :gen_tcp.close(socket)
    :ok
  end

  defp start_peer(socket, state) do
    peer_opts = [socket: socket, grants: state.grants]

    case DynamicSupervisor.start_child(state.peer_supervisor, {Peer, peer_opts}) do
      {:ok, pid} ->
        hand_over(socket, pid, state)

      {:error, reason} ->
        Logger.error("Browser bridge could not start a peer: #{inspect(reason)}")
        _ = :gen_tcp.close(socket)
        :ok
    end
  end

  # Ownership transfer: after this the Peer's exit closes the fd on every path,
  # so a dead reader can never leave the extension hanging without EOF.
  defp hand_over(socket, pid, state) do
    case :gen_tcp.controlling_process(socket, pid) do
      :ok ->
        send(pid, :socket_handover)
        :ok

      {:error, reason} ->
        Logger.error("Browser bridge socket handover failed: #{inspect(reason)}")
        _ = DynamicSupervisor.terminate_child(state.peer_supervisor, pid)
        _ = :gen_tcp.close(socket)
        :ok
    end
  end
end
