defmodule FermixChannels.Mobile.TlsTransport do
  @moduledoc """
  ThousandIsland's TLS transport for the mobile listener, with a handshake
  that ends and reads that end by the upgrade.

  ThousandIsland 1.4.3 runs `:ssl.handshake/1`, which waits forever, inside
  the connection process. The listener allows 64 connections before any
  authentication, so 64 peers that open TCP and never send a ClientHello would
  lock every phone, every pairing attempt and the doctor's probe out for as
  long as they stayed connected.

  Bandit then reads the HTTP request with a timeout per read that every byte
  restarts, so a peer that dribbles its request, or never ends a body Bandit
  drains, held its slot just as long. So the handshake starts a deadline for
  the whole connection up to its WebSocket upgrade, and every read waits no
  longer than what is left of it. `Mobile.SocketHandler` ends it once the
  socket is upgraded, where its own handshake deadline takes over.

  Every other call is the stock one.
  """

  @behaviour ThousandIsland.Transport

  alias ThousandIsland.Transport
  alias ThousandIsland.Transports.SSL

  @handshake_timeout_ms 10_000
  @upgrade_deadline_ms 15_000
  # ThousandIsland hands each callback only the socket, and calls the
  # handshake and every read of one connection in that connection's process,
  # which SocketHandler's init runs in too: the deadline lives in its
  # dictionary.
  @upgrade_deadline_key {__MODULE__, :upgrade_deadline}

  @doc "How long a peer has to finish the TLS handshake before it is closed."
  @spec handshake_timeout_ms() :: pos_integer()
  def handshake_timeout_ms, do: @handshake_timeout_ms

  @doc "How long a peer has from being accepted to its WebSocket upgrade."
  @spec upgrade_deadline_ms() :: pos_integer()
  def upgrade_deadline_ms, do: @upgrade_deadline_ms

  @impl Transport
  @spec handshake(:ssl.sslsocket()) :: Transport.on_handshake()
  def handshake(socket) do
    :ok = start_upgrade_deadline(@upgrade_deadline_ms)
    handshake(socket, @handshake_timeout_ms)
  end

  @doc """
  Starts the calling connection's upgrade deadline, `timeout_ms` from now.
  From then on a read waits no longer than what is left of it.
  """
  @spec start_upgrade_deadline(pos_integer()) :: :ok
  def start_upgrade_deadline(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    _previous = Process.put(@upgrade_deadline_key, now_ms() + timeout_ms)
    :ok
  end

  @doc "Ends the calling connection's upgrade deadline: its socket was upgraded."
  @spec clear_upgrade_deadline() :: :ok
  def clear_upgrade_deadline do
    _previous = Process.delete(@upgrade_deadline_key)
    :ok
  end

  @doc "The calling connection's upgrade deadline in monotonic milliseconds, or nil."
  @spec upgrade_deadline() :: integer() | nil
  def upgrade_deadline, do: Process.get(@upgrade_deadline_key)

  @doc """
  The handshake with its deadline passed in. A peer that has not finished by
  then is answered `{:error, :timeout}`, and `:ssl` closes its connection.
  """
  @spec handshake(:ssl.sslsocket(), pos_integer()) :: Transport.on_handshake()
  def handshake(socket, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    case :ssl.handshake(socket, timeout_ms) do
      {:ok, socket} -> {:ok, socket}
      {:ok, socket, _protocol_extensions} -> {:ok, socket}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Transport
  @spec listen(:inet.port_number(), [:ssl.tls_server_option()]) :: Transport.on_listen()
  defdelegate listen(port, options), to: SSL

  @impl Transport
  @spec accept(Transport.listener_socket()) :: Transport.on_accept()
  defdelegate accept(listener_socket), to: SSL

  @impl Transport
  @spec upgrade(Transport.socket(), term()) :: Transport.on_upgrade()
  defdelegate upgrade(socket, options), to: SSL

  @impl Transport
  @spec controlling_process(Transport.socket(), pid()) :: Transport.on_controlling_process()
  defdelegate controlling_process(socket, pid), to: SSL

  @impl Transport
  @spec recv(Transport.socket(), non_neg_integer(), timeout()) :: Transport.on_recv()
  def recv(socket, length, timeout) do
    case upgrade_deadline() do
      nil -> SSL.recv(socket, length, timeout)
      deadline -> recv_before(socket, length, timeout, deadline - now_ms())
    end
  end

  @impl Transport
  @spec send(Transport.socket(), iodata()) :: Transport.on_send()
  defdelegate send(socket, data), to: SSL

  @impl Transport
  @spec sendfile(Transport.socket(), String.t(), non_neg_integer(), non_neg_integer()) ::
          Transport.on_sendfile()
  defdelegate sendfile(socket, filename, offset, length), to: SSL

  @impl Transport
  @spec getopts(Transport.socket(), Transport.socket_get_options()) :: Transport.on_getopts()
  defdelegate getopts(socket, options), to: SSL

  @impl Transport
  @spec setopts(Transport.socket(), Transport.socket_set_options()) :: Transport.on_setopts()
  defdelegate setopts(socket, options), to: SSL

  @impl Transport
  @spec shutdown(Transport.socket(), Transport.way()) :: Transport.on_shutdown()
  defdelegate shutdown(socket, way), to: SSL

  @impl Transport
  @spec close(Transport.socket() | Transport.listener_socket()) :: Transport.on_close()
  defdelegate close(socket), to: SSL

  @impl Transport
  @spec sockname(Transport.socket() | Transport.listener_socket()) :: Transport.on_sockname()
  defdelegate sockname(socket), to: SSL

  @impl Transport
  @spec peername(Transport.socket()) :: Transport.on_peername()
  defdelegate peername(socket), to: SSL

  @impl Transport
  @spec peercert(Transport.socket()) :: Transport.on_peercert()
  defdelegate peercert(socket), to: SSL

  @impl Transport
  @spec secure?() :: true
  defdelegate secure?(), to: SSL

  @impl Transport
  @spec getstat(Transport.socket()) :: Transport.socket_stats()
  defdelegate getstat(socket), to: SSL

  @impl Transport
  @spec negotiated_protocol(Transport.socket()) :: Transport.on_negotiated_protocol()
  defdelegate negotiated_protocol(socket), to: SSL

  @impl Transport
  @spec connection_information(Transport.socket()) :: Transport.on_connection_information()
  defdelegate connection_information(socket), to: SSL

  # A read past the deadline closes the connection instead of answering
  # `:timeout`: Bandit reads a timeout in a chunked body as no bytes yet and
  # would ask again at once. The close's own result changes nothing, since the
  # connection is being given up either way.
  defp recv_before(socket, _length, _timeout, left_ms) when left_ms <= 0 do
    _closed = SSL.close(socket)
    {:error, :closed}
  end

  defp recv_before(socket, length, :infinity, left_ms), do: SSL.recv(socket, length, left_ms)

  defp recv_before(socket, length, timeout, left_ms),
    do: SSL.recv(socket, length, min(timeout, left_ms))

  defp now_ms, do: System.monotonic_time(:millisecond)
end
