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

  Anyone who knows the endpoint id can open streams that never say a word, and
  the helper bridges each one at once, so a full bridge does not turn the next
  stream away: it makes room by closing the connection it admitted first of
  those still in their handshake, and turns a stream away only when every
  session is past its handshake (`Session.past_handshake?/1`), which each
  connection tells the bridge as it happens. A connection asked for its place
  after its session got past its handshake stays, and the bridge serves one
  past its bound until a connection ends.

  Only a phone gets past its handshake: one whose IK handshake proved a paired
  phone's key, or the one pairing phone a window takes, whose request proved
  the window's secret and its attestation and waits for the owner. A stranger
  holds no place the bridge keeps, so it cannot fill the bridge, and each of
  its streams the bridge admits runs a session that ends with a `close` for
  its peer (`Session.terminate/2`), a stream closed to make room included. A
  stream is turned away only while phones hold every place, and is closed
  before its preamble is read: no session runs and no `close` is sent, so its
  iroh connection lasts until the helper's own bounds end it.

  The rail's outer bound is the helper's own: it takes 1,024 iroh connections
  (`Iroh.Helper.limits/0`), and when they are all taken it gives a new one the
  place of the connection that has gone longest with no stream open, so
  connections that never open a stream cannot keep a phone from reaching this
  bridge. It refuses one before its handshake only while every connection has
  a stream open, which takes a stranger about 200 new connections a second.
  That does not protect a pairing phone's stream here: a stranger who opens
  streams fast enough can still close it, since it stays in its handshake
  through the round trip to its `pair_request` and the attestation that may
  take seconds; a phone that prepares its attestation before it dials keeps
  that window short.

  The places are counted from the connections this process admitted and
  monitors. A bridge restarted while its old connections live starts with none
  of them: it relies on the rail's `rest_for_one`, which restarts the helper
  after it, and so ends every stream those connections carry.
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

  @doc """
  The most bridge connections served at once, the mobile listener's bound. It
  is exceeded by one for each connection that got past its handshake as the
  bridge asked for its place, until a connection ends.
  """
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
           max_connections: Keyword.get(opts, :max_connections, @max_connections),
           connections: %{},
           admitted: 0,
           made_room: 0,
           refused: 0
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
        state = accept_connection(socket, state)
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

  # A connection that ended frees its place; one let go to make room was
  # demonitored then.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, %{state | connections: Map.delete(state.connections, pid)}}

  @impl true
  # A connection's session got past its handshake (`BridgeConnection`).
  def handle_cast({:past_handshake, pid}, state) when is_pid(pid),
    do: {:noreply, past_handshake(pid, state)}

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

  # The backlog holds a burst of streams the helper opens at once, up to the
  # bound; the default of 5 would refuse the sixth as unreachable.
  defp listen(path) do
    :gen_tcp.listen(0, [
      :binary,
      {:active, false},
      {:backlog, @max_connections},
      {:ifaddr, {:local, path}}
    ])
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

  defp accept_connection(socket, %{connections: connections, max_connections: max} = state)
       when map_size(connections) < max,
       do: start_connection(socket, state)

  defp accept_connection(socket, state) do
    case first_in_handshake(state.connections) do
      nil -> refuse(socket, state)
      pid -> start_connection(socket, make_room(pid, state))
    end
  end

  defp first_in_handshake(connections) do
    in_handshake =
      for {pid, %{past_handshake?: false, order: order}} <- connections, do: {order, pid}

    case Enum.min(in_handshake, fn -> nil end) do
      nil -> nil
      {_order, pid} -> pid
    end
  end

  # The connection closes itself (`BridgeConnection`); the bridge lets it go at
  # once, so the newcomer takes its place now. One that got past its handshake
  # before it read the request stays, and the word it sent puts it back.
  defp make_room(pid, state) do
    {%{monitor: ref}, connections} = Map.pop!(state.connections, pid)
    Process.demonitor(ref, [:flush])
    :ok = GenServer.cast(pid, :make_room)
    count = state.made_room + 1
    :ok = warn_full(count, "closed", "still in the handshake")
    %{state | connections: connections, made_room: count}
  end

  # Every place holds a phone's session. The stream gets no session, so its
  # peer gets no `close`: the helper's own bounds end its connection.
  defp refuse(socket, state) do
    count = state.refused + 1
    :ok = warn_full(count, "refused", "with every session past its handshake")
    _ = :gen_tcp.close(socket)
    %{state | refused: count}
  end

  defp past_handshake(pid, state) do
    case state.connections do
      %{^pid => connection} ->
        connection = %{connection | past_handshake?: true}
        %{state | connections: Map.put(state.connections, pid, connection)}

      _let_go ->
        track(pid, true, state)
    end
  end

  # Said at 1, 10, 100… of each, as `Iroh.Helper` says its refusals, so a flood
  # costs a few log lines.
  defp warn_full(count, done, why) do
    if power_of_ten?(count) do
      noun = if count == 1, do: "stream", else: "streams"
      Logger.warning("bridge socket full: #{done} #{count} remote #{noun} #{why}")
    end

    :ok
  end

  defp power_of_ten?(1), do: true
  defp power_of_ten?(count) when rem(count, 10) == 0, do: power_of_ten?(div(count, 10))
  defp power_of_ten?(_count), do: false

  defp start_connection(socket, state) do
    opts = Keyword.merge(state.connection_opts, socket: socket, bridge: self())

    case DynamicSupervisor.start_child(state.connection_supervisor, {BridgeConnection, opts}) do
      {:ok, pid} ->
        hand_over(socket, pid, state)

      {:error, reason} ->
        Logger.error("bridge socket could not start a connection: #{inspect(reason)}")
        _ = :gen_tcp.close(socket)
        state
    end
  end

  defp hand_over(socket, pid, state) do
    case :gen_tcp.controlling_process(socket, pid) do
      :ok ->
        send(pid, :socket_handover)
        track(pid, false, state)

      {:error, reason} ->
        Logger.error("bridge socket handover failed: #{inspect(reason)}")
        _ = DynamicSupervisor.terminate_child(state.connection_supervisor, pid)
        _ = :gen_tcp.close(socket)
        state
    end
  end

  # Admission order, not a clock, says which connection came first.
  defp track(pid, past_handshake?, state) do
    connection = %{
      monitor: Process.monitor(pid),
      order: state.admitted,
      past_handshake?: past_handshake?
    }

    %{
      state
      | connections: Map.put(state.connections, pid, connection),
        admitted: state.admitted + 1
    }
  end
end
