defmodule FermixChannels.Mobile.Router do
  @moduledoc """
  The intentionally small HTTP surface for the iOS companion listener.

  Only liveness and WebSocket upgrade routes exist. All application messages
  travel inside the authenticated Noise session after upgrade.
  """

  @behaviour Plug

  import Plug.Conn

  alias FermixChannels.Mobile.PairManager
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Mobile.SocketHandler

  # The upgrade happens before the prelude picks paired or pairing mode, so one
  # idle timeout covers both. It must outlive the owner-approval window, or the
  # transport closes a pairing socket while the owner is still deciding.
  @idle_grace_ms 30_000
  # A Noise message is at most 65,535 bytes, and Bandit counts the frame header
  # against its cap: 14 bytes is the largest masked client header (2, an 8-byte
  # extended length, and the 4-byte mask).
  @max_frame_size 65_535 + 14
  # Bandit buffers every FIN=0 fragment of a message with no bound on the total,
  # before the prelude is even read. Counting shared binaries against the heap
  # makes that buffer count too, so an unauthenticated connection that outgrows
  # a handshake's needs is killed instead of the VM.
  @unauthenticated_heap_bytes 4 * 1_024 * 1_024
  # A paired device's socket carries media: a fetched blob with its frames and
  # their ciphertext, and fan-out events queued in its mailbox.
  @authenticated_heap_floor_bytes 64 * 1_024 * 1_024
  @default_max_media_bytes 20 * 1_024 * 1_024

  @doc "The WebSocket frame cap: the largest Noise message plus its largest header."
  @spec max_frame_size() :: pos_integer()
  def max_frame_size, do: @max_frame_size

  @impl true
  @spec init(keyword()) :: keyword()
  def init(opts) when is_list(opts), do: opts

  @impl true
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{method: "GET", path_info: ["healthz"]} = conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{fermix: "mobile", v: Protocol.protocol_version()}))
  end

  def call(%Plug.Conn{method: "GET", path_info: ["ws"]} = conn, opts) do
    if websocket_upgrade?(conn) do
      WebSockAdapter.upgrade(conn, SocketHandler, handler_state(conn, opts), socket_options())
    else
      conn |> put_resp_header("upgrade", "websocket") |> send_resp(426, "upgrade required")
    end
  end

  def call(%Plug.Conn{} = conn, _opts), do: send_resp(conn, 404, "not found")

  defp socket_options do
    [
      compress: false,
      max_frame_size: @max_frame_size,
      timeout: PairManager.max_ttl_ms() + @idle_grace_ms,
      max_heap_size: heap_cap(@unauthenticated_heap_bytes)
    ]
  end

  # Pairing failures are counted per source address, so a noisy peer is refused
  # alone and the window stays open: this connection's pairing calls carry its own.
  defp handler_state(conn, opts) do
    source = conn.remote_ip
    max_media_bytes = Keyword.get(opts, :max_media_bytes, @default_max_media_bytes)

    opts
    |> Map.new()
    |> Map.put(:authenticated_max_heap_size, authenticated_heap_cap(max_media_bytes))
    |> Map.put_new(:current_pair, &PairManager.current(&1, source))
    |> Map.put_new(:record_pair_failure, &PairManager.record_failure(&1, &2, source))
  end

  defp authenticated_heap_cap(max_media_bytes) when is_integer(max_media_bytes) do
    heap_cap(@authenticated_heap_floor_bytes + 4 * max_media_bytes)
  end

  defp heap_cap(bytes) do
    %{
      size: div(bytes, :erlang.system_info(:wordsize)),
      kill: true,
      error_logger: true,
      include_shared_binaries: true
    }
  end

  defp websocket_upgrade?(conn) do
    upgrade =
      conn |> get_req_header("upgrade") |> Enum.any?(&(String.downcase(&1) == "websocket"))

    connection =
      conn
      |> get_req_header("connection")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.any?(&(String.downcase(String.trim(&1)) == "upgrade"))

    upgrade and connection
  end
end
