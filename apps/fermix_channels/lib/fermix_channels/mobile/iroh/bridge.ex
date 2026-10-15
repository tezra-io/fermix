defmodule FermixChannels.Mobile.Iroh.Bridge do
  @moduledoc """
  The bridge socket: the Unix-domain listener `fermix-iroh` connects to once
  for each iroh stream it accepts (`fermix_core/priv/iroh_helper/PROTOCOL.md`,
  *The bridge*), at `<home>/mobile/bridge.sock`, mode `0600`.

  The `Companion.Endpoint` shape: a stale-socket probe, a bound on connections
  at once, and one `Iroh.BridgeConnection` per accepted socket under the rail's
  connection supervisor, handed the socket with `controlling_process/2` so the
  fd closes the instant that connection exits. A socket it cannot bind costs
  the rail and nothing else: it logs one actionable error and returns
  `:ignore`, and `Iroh.Helper` reports the rail failed rather than start a
  helper with nowhere to bridge to.
  """

  use GenServer

  require Logger

  alias FermixChannels.Mobile.Iroh.BridgeConnection
  alias FermixCore.SocketPath

  @max_connections 64
  @accept_idle_ms 50
  @accept_retry_ms 1_000

  @doc "The bridge socket's path under a Fermix home."
  @spec socket_path(Path.t()) :: Path.t()
  def socket_path(root) when is_binary(root) and root != "",
    do: Path.join([root, "mobile", "bridge.sock"])

  @doc "The most bridge connections served at once, the mobile listener's bound."
  @spec max_connections() :: pos_integer()
  def max_connections, do: @max_connections

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Whether the bridge is listening (its process is up only while it is)."
  @spec listening?(GenServer.server()) :: boolean()
  def listening?(server) when is_pid(server), do: Process.alive?(server)
  def listening?(server), do: not is_nil(GenServer.whereis(server))

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    path = Keyword.fetch!(opts, :socket_path)

    case bind(path) do
      {:ok, listen_socket} ->
        send(self(), :accept)

        {:ok,
         %{
           listen_socket: listen_socket,
           socket_path: path,
           connection_supervisor: Keyword.fetch!(opts, :connection_supervisor),
           connection_opts: Keyword.get(opts, :connection_opts, []),
           max_connections: Keyword.get(opts, :max_connections, @max_connections)
         }}

      {:error, reason} ->
        Logger.error(
          "remote reach is off for this boot: the bridge socket #{path} could not be " <>
            "opened (#{inspect(reason)}). Check #{Path.dirname(path)}, then restart."
        )

        :ignore
    end
  end

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.listen_socket, @accept_idle_ms) do
      {:ok, socket} ->
        :ok = accept_connection(socket, state)
        send(self(), :accept)
        {:noreply, state}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, :closed} ->
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.warning("bridge socket accept error: #{inspect(reason)}")
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

  defp bind(path) do
    with :ok <- SocketPath.check(path),
         :ok <- clear_stale_socket(path),
         {:ok, listen_socket} <- listen(path) do
      chmod_socket(path, listen_socket)
    end
  end

  defp listen(path) do
    :gen_tcp.listen(0, [:binary, {:active, false}, {:ifaddr, {:local, path}}])
  end

  defp chmod_socket(path, listen_socket) do
    case File.chmod(path, 0o600) do
      :ok ->
        {:ok, listen_socket}

      {:error, reason} ->
        _ = :gen_tcp.close(listen_socket)
        _ = File.rm(path)
        {:error, {:chmod, reason}}
    end
  end

  defp clear_stale_socket(path) do
    cond do
      not File.exists?(path) -> :ok
      live_socket?(path) -> {:error, {:another_bridge_running, path}}
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
      {:error, reason} -> {:error, {:stale_socket_unlink_failed, reason}}
    end
  end

  defp accept_connection(socket, state) do
    %{active: active} = DynamicSupervisor.count_children(state.connection_supervisor)

    if active >= state.max_connections do
      Logger.warning("bridge socket refusing a stream: #{active} already connected")
      _ = :gen_tcp.close(socket)
      :ok
    else
      start_connection(socket, state)
    end
  end

  defp start_connection(socket, state) do
    opts = Keyword.put(state.connection_opts, :socket, socket)

    case DynamicSupervisor.start_child(state.connection_supervisor, {BridgeConnection, opts}) do
      {:ok, pid} ->
        hand_over(socket, pid, state)

      {:error, reason} ->
        Logger.error("bridge socket could not start a connection: #{inspect(reason)}")
        _ = :gen_tcp.close(socket)
        :ok
    end
  end

  defp hand_over(socket, pid, state) do
    case :gen_tcp.controlling_process(socket, pid) do
      :ok ->
        send(pid, :socket_handover)
        :ok

      {:error, reason} ->
        Logger.error("bridge socket handover failed: #{inspect(reason)}")
        _ = DynamicSupervisor.terminate_child(state.connection_supervisor, pid)
        _ = :gen_tcp.close(socket)
        :ok
    end
  end
end
