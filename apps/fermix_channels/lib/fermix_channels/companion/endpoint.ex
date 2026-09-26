defmodule FermixChannels.Companion.Endpoint do
  @moduledoc """
  The companion chat socket's Unix-domain listener.

  Binds `<FERMIX_HOME>/companion.sock` at 0600, the same class of surface as the
  Realtime voice socket, the ACP socket and the daemon control socket: same user,
  same machine, no network. One accept loop hands each accepted socket to a
  `Companion.Connection` started under the dynamic connection supervisor,
  transferring ownership with `controlling_process/2` so the fd closes the
  instant that connection exits, however it exits.

  Two protections live here because they apply before a connection exists: a
  stale-socket probe (a socket file left by a crashed daemon is unlinked; a live
  one refuses to be stolen) and the client cap, the Realtime socket's: a
  connection over it is answered with one `error` (`max_clients_reached`) and
  closed.

  The socket runs whenever the daemon runs; it depends on no feature flag. A
  socket it cannot bind costs this surface and nothing else: `init/1` logs one
  actionable error naming the path and the reason and returns `:ignore`, and
  the daemon boots without it. It never retries and never falls back to another
  path or transport.
  """

  use GenServer

  require Logger

  alias FermixChannels.Companion.Connection
  alias FermixCore.Companion.Protocol
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.SocketPath

  @max_clients 4
  @accept_idle_ms 50
  @accept_retry_ms 1_000
  @socket_name "companion.sock"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The socket path this listener binds: `companion.sock` under `FERMIX_HOME`."
  @spec socket_path() :: String.t()
  def socket_path, do: Path.join(ConfigStore.fermix_home(), @socket_name)

  @doc "The most clients served at once, the Realtime socket's cap."
  @spec max_clients() :: pos_integer()
  def max_clients, do: @max_clients

  @doc "How many client connections are being served right now."
  @spec connection_count(GenServer.server()) :: non_neg_integer()
  def connection_count(server \\ __MODULE__), do: GenServer.call(server, :connection_count)

  @impl true
  def init(opts) do
    # Trap exits so `terminate/2` runs on a supervisor shutdown: the listen
    # socket and its socket file are this process's resources.
    Process.flag(:trap_exit, true)

    path = Keyword.get(opts, :socket_path, socket_path())

    case bind(path) do
      {:ok, listen_socket} ->
        Process.send_after(self(), :accept, 0)
        Logger.info("companion socket listening on #{path}")
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
        Logger.warning("companion socket accept error: #{inspect(reason)}")
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
      connection_supervisor: Keyword.fetch!(opts, :connection_supervisor),
      connection_opts: Keyword.get(opts, :connection_opts, []),
      max_clients: Keyword.get(opts, :max_clients, @max_clients)
    }
  end

  # Every step that can fail on an operator's machine, in the order the OS cares
  # about, each failure carrying the stage it came from.
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
      {:reuseaddr, true}
    ])
  end

  # An 0666 chat socket is a wider surface than no chat socket.
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
    "the companion socket is disabled for this boot: " <>
      SocketPath.refusal("companion socket", bytes, limit) <> ". Path: #{path}"
  end

  defp refusal({:another_companion_socket_running, _path}, path) do
    "the companion socket is disabled for this boot: another daemon is already listening " <>
      "on #{path}. Stop it, or give this daemon its own FERMIX_HOME, then restart."
  end

  defp refusal({:stale_socket_unlink_failed, reason, _path}, path) do
    "the companion socket is disabled for this boot: a stale socket file at #{path} " <>
      "could not be removed (#{inspect(reason)}). Delete it and restart."
  end

  defp refusal({stage, reason}, path) when reason in [:eacces, :eperm] do
    "the companion socket is disabled for this boot: permission denied (#{stage}) on " <>
      "#{path}. Check the ownership and mode of #{Path.dirname(path)}, then restart."
  end

  defp refusal({stage, reason}, path) do
    "the companion socket is disabled for this boot: #{path} could not be opened, " <>
      "#{stage} failed with #{inspect(reason)}. Everything else on this daemon is running."
  end

  # Probe before unlinking. A live listener answers, and stealing its path would
  # leave it serving clients at an address nobody can reach again; a stale file
  # from a crashed daemon refuses and is removed.
  defp clear_stale_socket(path) do
    cond do
      not File.exists?(path) -> :ok
      live_socket?(path) -> {:error, {:another_companion_socket_running, path}}
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

  # The connection supervisor's live child count is the connection count: a
  # connection owns its socket, so it exists exactly as long as its process.
  defp connections(state) do
    %{active: active} = DynamicSupervisor.count_children(state.connection_supervisor)
    active
  end

  defp accept_connection(socket, state) do
    if connections(state) >= state.max_clients do
      refuse(socket, state)
    else
      start_connection(socket, state)
    end
  end

  defp refuse(socket, state) do
    Logger.warning(
      "companion socket refusing a client: #{state.max_clients} clients already connected"
    )

    with {:ok, line} <-
           Protocol.encode_server_event("error", %{"reason" => "max_clients_reached"}) do
      _ = :gen_tcp.send(socket, line)
    end

    _ = :gen_tcp.close(socket)
    :ok
  end

  defp start_connection(socket, state) do
    opts = Keyword.put(state.connection_opts, :socket, socket)

    case DynamicSupervisor.start_child(state.connection_supervisor, {Connection, opts}) do
      {:ok, pid} ->
        hand_over(socket, pid, state)

      {:error, reason} ->
        Logger.error("companion socket could not start a connection: #{inspect(reason)}")
        _ = :gen_tcp.close(socket)
        :ok
    end
  end

  # After this the connection's exit closes the fd on every path, so a dead
  # reader can never leave a client hanging without EOF.
  defp hand_over(socket, pid, state) do
    case :gen_tcp.controlling_process(socket, pid) do
      :ok ->
        send(pid, :socket_handover)
        :ok

      {:error, reason} ->
        Logger.error("companion socket handover failed: #{inspect(reason)}")
        _ = DynamicSupervisor.terminate_child(state.connection_supervisor, pid)
        _ = :gen_tcp.close(socket)
        :ok
    end
  end
end
