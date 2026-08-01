defmodule FermixChannels.Channels.Acp.Endpoint do
  @moduledoc """
  The ACP Unix-domain listener (MILESTONE_29_ACP_AGENT_SURFACE.md §6.1).

  Binds `<FERMIX_HOME>/acp.sock` at 0600 — the same class of surface as the
  realtime voice socket and the daemon control socket: same user, same machine,
  no network. One accept loop hands each accepted socket to a `Channels.Acp.Peer`
  started under the dynamic peer supervisor, transferring ownership with
  `controlling_process/2` so the fd closes the instant that Peer exits, however
  it exits.

  Two protections live here rather than in the Peer, because they apply before a
  Peer exists: a **stale-socket probe** (a socket file left by a crashed daemon
  is unlinked; a *live* one refuses to be stolen) and the **connection cap** — a
  connection over the cap is answered in the bridge's own language (an error ack)
  and closed, so the operator sees a reason instead of a silent EOF.

  ACP is an **optional** transport that ships on by default, so a socket it
  cannot bind costs the ACP surface and nothing else: `init/1` logs one
  actionable error naming the path and the reason, then returns `:ignore` — the
  OTP answer for "this optional child cannot run" — and the daemon boots without
  it. It never retries and never falls back to another path or transport; the
  operator fixes the named cause and restarts. `/health` reports the channel as
  `degraded` because its listener process is absent.
  """

  use GenServer

  require Logger

  alias FermixChannels.Channels.Acp
  alias FermixChannels.Channels.Acp.Peer
  alias FermixCore.Setup.ConfigStore

  # Two Buzz agents at max parallelism (32 slots each) fit inside this.
  @max_connections 64
  @accept_idle_ms 50
  @accept_retry_ms 1_000
  @socket_name "acp.sock"

  # `struct sockaddr_un.sun_path` is a fixed char array and the address has to
  # fit inside it with its NUL terminator: 104 bytes on macOS/BSD, 108 on Linux.
  # A longer path fails the bind with a bare `:einval`, which reads as a Fermix
  # bug rather than as "your FERMIX_HOME is too long" — hence the pre-flight
  # below, which measures the path STRING and touches no filesystem object.
  # Resolved at runtime, not compiled in: a release cross-built on one OS has to
  # measure against the OS it actually runs on.
  @sun_path_bytes_darwin 104
  @sun_path_bytes_linux 108

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The socket path this listener binds: `acp.sock` under `FERMIX_HOME`."
  @spec socket_path() :: String.t()
  def socket_path, do: Path.join(ConfigStore.fermix_home(), @socket_name)

  @doc "How many client connections are being served right now."
  @spec connection_count(GenServer.server()) :: non_neg_integer()
  def connection_count(server \\ __MODULE__), do: GenServer.call(server, :connection_count)

  @impl true
  def init(opts) do
    # Trap exits so `terminate/2` runs on a supervisor shutdown: the listen
    # socket and its socket FILE are this process's resources, and they are
    # released on every exit path, not only on a crash the next boot's
    # stale-probe would have to clean up after.
    Process.flag(:trap_exit, true)

    path = Keyword.get(opts, :socket_path, socket_path())

    case bind(path) do
      {:ok, listen_socket} ->
        Process.send_after(self(), :accept, 0)
        Logger.info("ACP endpoint listening on #{path}")
        {:ok, build_state(listen_socket, path, opts)}

      {:error, reason} ->
        Logger.error(refusal(reason, path))
        :ignore
    end
  end

  @impl true
  def handle_call(:connection_count, _from, state) do
    {:reply, connections(state), state}
  end

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
        Logger.warning("ACP endpoint accept error: #{inspect(reason)}")
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
      registry: Keyword.get(opts, :registry, Acp.registry()),
      peer_supervisor: Keyword.get(opts, :peer_supervisor, Acp.Supervisor.peer_supervisor()),
      peer_opts: Keyword.get(opts, :peer_opts, []),
      max_connections: Keyword.get(opts, :max_connections, @max_connections)
    }
  end

  # Every step that can fail on an operator's machine, in the order the OS cares
  # about. Each failure carries the stage it came from, so a bare `:eacces` says
  # which operation the kernel refused rather than a single blurred message.
  defp bind(path) do
    with :ok <- check_path_length(path),
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

  # Pre-flight on the path STRING — never on a filesystem object this listener
  # is about to create, which would fail closed on a clean first-run install.
  defp check_path_length(path) do
    limit = max_socket_path_bytes()

    if byte_size(path) > limit do
      {:error, {:path_too_long, byte_size(path), limit}}
    else
      :ok
    end
  end

  # Linux gets its own four bytes; every other OS is measured against the smaller
  # macOS/BSD array. Erring small can only over-refuse by four bytes with a
  # message that still names the true fix; erring large hands back the `:einval`
  # this check exists to translate.
  defp max_socket_path_bytes do
    case :os.type() do
      {:unix, :linux} -> @sun_path_bytes_linux - 1
      _other -> @sun_path_bytes_darwin - 1
    end
  end

  defp listen(path) do
    :gen_tcp.listen(0, [
      :binary,
      {:active, false},
      {:ifaddr, {:local, path}},
      {:reuseaddr, true}
    ])
  end

  # The listen socket is this function's to own the moment the mode cannot be
  # tightened: an 0666 ACP socket is a wider surface than no ACP socket.
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
    "ACP is disabled for this boot: the ACP socket path is #{bytes} bytes, over the " <>
      "#{limit}-byte limit this OS allows for a unix socket address — set a shorter " <>
      "FERMIX_HOME and restart. Path: #{path}"
  end

  defp refusal({:another_acp_socket_running, _path}, path) do
    "ACP is disabled for this boot: another ACP daemon is already listening on #{path}. " <>
      "Stop it, or give this daemon its own FERMIX_HOME, then restart."
  end

  defp refusal({:stale_socket_unlink_failed, reason, _path}, path) do
    "ACP is disabled for this boot: a stale ACP socket file at #{path} could not be " <>
      "removed (#{inspect(reason)}). Delete it and restart."
  end

  defp refusal({stage, reason}, path) when reason in [:eacces, :eperm] do
    "ACP is disabled for this boot: permission denied (#{stage}) on the ACP socket #{path}. " <>
      "Check the ownership and mode of #{Path.dirname(path)}, then restart."
  end

  defp refusal({stage, :eaddrinuse}, path) do
    "ACP is disabled for this boot: the ACP socket address #{path} is already in use " <>
      "(#{stage}). Stop whatever holds it, or delete the socket file, then restart."
  end

  defp refusal({stage, reason}, path) do
    "ACP is disabled for this boot: the ACP socket #{path} could not be opened — " <>
      "#{stage} failed with #{inspect(reason)}. Everything else on this daemon is running."
  end

  # Probe before unlinking. A live listener answers, and stealing its path would
  # leave it serving clients at an address nobody can reach again; a stale file
  # from a crashed daemon refuses and is removed. Same discipline as the realtime
  # voice socket and the daemon control socket.
  defp clear_stale_socket(path) do
    cond do
      not File.exists?(path) -> :ok
      live_socket?(path) -> {:error, {:another_acp_socket_running, path}}
      true -> unlink_stale(path)
    end
  end

  defp live_socket?(path) do
    case :gen_tcp.connect({:local, to_charlist(path)}, 0, [:binary, {:active, false}], 500) do
      {:ok, socket} ->
        _ = :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
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
      "ACP endpoint refusing a connection: #{state.max_connections} connections already active"
    )

    _ =
      :gen_tcp.send(
        socket,
        Peer.refusal_line("too many ACP connections (max #{state.max_connections})")
      )

    _ = :gen_tcp.close(socket)
    :ok
  end

  defp start_peer(socket, state) do
    peer_opts =
      state.peer_opts
      |> Keyword.put(:socket, socket)
      |> Keyword.put(:registry, state.registry)

    case DynamicSupervisor.start_child(state.peer_supervisor, {Peer, peer_opts}) do
      {:ok, pid} ->
        hand_over(socket, pid, state)

      {:error, reason} ->
        Logger.error("ACP endpoint could not start a peer: #{inspect(reason)}")
        _ = :gen_tcp.close(socket)
        :ok
    end
  end

  # Ownership transfer: after this the Peer's exit closes the fd on every path,
  # so a dead reader can never leave a client hanging without EOF.
  defp hand_over(socket, pid, state) do
    case :gen_tcp.controlling_process(socket, pid) do
      :ok ->
        send(pid, :socket_handover)
        :ok

      {:error, reason} ->
        Logger.error("ACP endpoint socket handover failed: #{inspect(reason)}")
        _ = DynamicSupervisor.terminate_child(state.peer_supervisor, pid)
        _ = :gen_tcp.close(socket)
        :ok
    end
  end
end
