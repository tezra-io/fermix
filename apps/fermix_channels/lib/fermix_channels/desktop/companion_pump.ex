defmodule FermixChannels.Desktop.CompanionPump do
  @moduledoc """
  One tunneled companion channel on the primary (M75 §6): the far end of an
  ordinary `Companion.Connection`'s socket, which this process owns and
  serves to the desktop over its session.

  ## The socket

  `Companion.Connection` owns a stream socket and places the process on its
  other end before it reads a line (`FermixCore.SocketPeer`). The pump gives
  it one by the shortest route that keeps the connection unchanged: a private
  Unix socket made under the home (`<home>/mobile`, `0700`), listened on with
  a backlog of one, connected to and accepted at once, and gone (file and
  listener) before the connection starts. The accepted end must name this
  engine as its peer, or nothing is served. Its peer is then the primary
  engine itself, which `SocketPeer` places as independent (the daemon is not
  its own descendant), so the connection serves the channel with the owner's
  trust: the trust the desktop's own `companion.sock` gave the one process it
  carries, the owner's app, which the desktop placed with the same resolver
  before it opened the channel. Nothing else crosses the tunnel.

  ## Lines

  Each line the connection writes goes to the desktop as one `companion_line`
  of this channel, without its newline; a line over the wire's 1 MiB cannot
  be carried, and ends the channel with its reason. Each line from the
  desktop is written to the connection. When the connection ends, however it
  ends (its socket reads closed after its last line, so a refusal it wrote
  reaches the desktop first), the desktop is sent `companion_close`; when the desktop closes the
  channel, or its session ends, the pump stops and the connection reads its
  socket closed.
  """

  use GenServer, restart: :temporary

  require Logger

  alias FermixChannels.Companion.Connection
  alias FermixChannels.Companion.Endpoint
  alias FermixChannels.Desktop.Peer
  alias FermixChannels.Mobile.Chunks
  alias FermixCore.SocketPath
  alias FermixCore.SocketPeer

  @accept_timeout_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Writes one line from the desktop to the channel's connection."
  @spec line(pid(), binary()) :: :ok
  def line(pump, line) when is_pid(pump) and is_binary(line) do
    send(pump, {:pump_line, line})
    :ok
  end

  @impl true
  def init(opts) do
    # `terminate/2` tells the family the channel ended, however the pump ends.
    Process.flag(:trap_exit, true)
    {:ok, line_bound} = Chunks.bound("companion_line")

    state = %{
      device_id: Keyword.fetch!(opts, :device_id),
      channel: Keyword.fetch!(opts, :channel),
      registry: Keyword.fetch!(opts, :registry),
      endpoint: Keyword.fetch!(opts, :endpoint),
      supervisor: Keyword.fetch!(opts, :supervisor),
      socket_dir: Keyword.fetch!(opts, :socket_dir),
      line_bound: line_bound,
      client: nil,
      buffer: "",
      closed_by: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    with {:ok, connection_opts} <- Endpoint.connection_opts(state.endpoint),
         {:ok, client, server} <- socket_pair(state.socket_dir),
         {:ok, _connection} <- start_connection(state.supervisor, connection_opts, server) do
      arm(%{state | client: client})
    else
      {:error, reason} ->
        Logger.error("desktop companion pump: channel #{state.channel}: #{inspect(reason)}")
        {:stop, :normal, %{state | closed_by: "The server could not open this chat."}}
    end
  end

  @impl true
  def handle_info({:tcp, client, bytes}, %{client: client} = state) do
    case lines(%{state | buffer: state.buffer <> bytes}) do
      {:ok, state} -> arm(state)
      {:error, reason, state} -> {:stop, :normal, %{state | closed_by: reason}}
    end
  end

  def handle_info({:tcp_closed, client}, %{client: client} = state),
    do: {:stop, :normal, %{state | closed_by: :connection}}

  def handle_info({:tcp_error, client, _reason}, %{client: client} = state),
    do: {:stop, :normal, %{state | closed_by: :connection}}

  def handle_info({:pump_line, line}, %{client: client} = state) when not is_nil(client) do
    case :gen_tcp.send(client, [line, "\n"]) do
      :ok -> {:noreply, state}
      {:error, _reason} -> {:stop, :normal, %{state | closed_by: :connection}}
    end
  end

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info(message, state) do
    Logger.debug("desktop companion pump ignored #{inspect(message)}")
    {:noreply, state}
  end

  # The desktop is told the channel ended when this side ended it; the
  # family forgets it in every case. Closing the socket ends the connection.
  @impl true
  def terminate(_reason, state) do
    if state.client, do: :gen_tcp.close(state.client)
    :ok = tell_desktop(state)

    _ =
      Peer.tell(state.device_id, :companion, {:pump_ended, state.channel, self()},
        registry: state.registry
      )

    :ok
  end

  defp tell_desktop(%{closed_by: nil}), do: :ok

  defp tell_desktop(state) do
    event =
      %{"t" => "companion_close", "channel" => state.channel}
      |> put_reason(state.closed_by)

    case Peer.send(state.device_id, event, <<>>, registry: state.registry) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug("desktop companion pump: close not sent: #{inspect(reason)}")
    end

    :ok
  end

  defp put_reason(event, reason) when is_binary(reason), do: Map.put(event, "reason", reason)
  defp put_reason(event, _connection_ended), do: event

  # -- the private socket -------------------------------------------------------

  defp socket_pair(dir) do
    path =
      Path.join(
        dir,
        "tunnel-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower) <> ".sock"
      )

    with :ok <- SocketPath.check(path),
         {:ok, listen} <- listen(path) do
      try do
        connect_and_accept(path, listen)
      after
        _ = :gen_tcp.close(listen)
        _ = File.rm(path)
      end
    end
  end

  defp listen(path) do
    with {:ok, listen} <-
           :gen_tcp.listen(0, [
             :binary,
             {:active, false},
             {:backlog, 1},
             {:ifaddr, {:local, path}}
           ]) do
      case File.chmod(path, 0o600) do
        :ok -> {:ok, listen}
        {:error, reason} -> close_all([listen], {:chmod, reason})
      end
    end
  end

  defp connect_and_accept(path, listen) do
    with {:ok, client} <- :gen_tcp.connect({:local, path}, 0, [:binary, {:active, false}]),
         {:ok, server} <- accept(listen, client) do
      own_peer(client, server)
    end
  end

  defp accept(listen, client) do
    case :gen_tcp.accept(listen, @accept_timeout_ms) do
      {:ok, server} -> {:ok, server}
      {:error, reason} -> close_all([client], {:accept, reason})
    end
  end

  # The socket file lived for an instant in a private directory; whatever
  # connected to it must still be this engine, or nothing is served.
  defp own_peer(client, server) do
    own = String.to_integer(System.pid())

    case SocketPeer.peer_os_pid(server) do
      {:ok, ^own} -> {:ok, client, server}
      {:ok, other} -> close_all([client, server], {:foreign_peer, other})
      {:error, reason} -> close_all([client, server], {:peer_unknown, reason})
    end
  end

  defp close_all(sockets, reason) do
    Enum.each(sockets, &:gen_tcp.close/1)
    {:error, reason}
  end

  defp start_connection(supervisor, connection_opts, server) do
    spec = {Connection, Keyword.put(connection_opts, :socket, server)}

    with {:ok, connection} <- DynamicSupervisor.start_child(supervisor, spec),
         :ok <- hand_over(server, connection, supervisor) do
      {:ok, connection}
    else
      {:error, reason} ->
        _ = :gen_tcp.close(server)
        {:error, {:connection, reason}}
    end
  end

  defp hand_over(server, connection, supervisor) do
    case :gen_tcp.controlling_process(server, connection) do
      :ok ->
        send(connection, :socket_handover)
        :ok

      {:error, reason} ->
        _ = DynamicSupervisor.terminate_child(supervisor, connection)
        {:error, {:handover, reason}}
    end
  end

  # -- lines -----------------------------------------------------------------------

  defp arm(state) do
    case :inet.setopts(state.client, active: :once) do
      :ok -> {:noreply, state}
      {:error, _reason} -> {:stop, :normal, %{state | closed_by: :connection}}
    end
  end

  defp lines(state) do
    case :binary.split(state.buffer, "\n") do
      [line, rest] -> state |> Map.put(:buffer, rest) |> carry(line)
      [partial] -> bounded(partial, state)
    end
  end

  defp carry(state, ""), do: lines(state)

  defp carry(state, line) when byte_size(line) > state.line_bound,
    do: {:error, too_long(), state}

  defp carry(state, line) do
    event = %{"t" => "companion_line", "channel" => state.channel}

    case Peer.send(state.device_id, event, line, registry: state.registry) do
      :ok ->
        lines(state)

      {:error, reason} ->
        Logger.warning("desktop companion pump: a line was not sent: #{inspect(reason)}")
        {:error, "The chat could not reach this desktop.", state}
    end
  end

  defp bounded(partial, state) do
    if byte_size(partial) > state.line_bound,
      do: {:error, too_long(), state},
      else: {:ok, state}
  end

  defp too_long, do: "A line from the server was too long to carry to this desktop."
end
