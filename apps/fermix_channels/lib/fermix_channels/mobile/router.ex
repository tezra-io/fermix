defmodule FermixChannels.Mobile.Router do
  @moduledoc """
  The intentionally small HTTP surface for the iOS companion listener.

  Only liveness and WebSocket upgrade routes exist. All application messages
  travel inside the authenticated Noise session after upgrade.
  """

  @behaviour Plug

  import Plug.Conn

  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Mobile.Session
  alias FermixChannels.Mobile.SocketHandler

  # A Noise message is at most 65,535 bytes, and Bandit counts the frame header
  # against its cap: 14 bytes is the largest masked client header (2, an 8-byte
  # extended length, and the 4-byte mask).
  @max_frame_size 65_535 + 14
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

  # The idle bound and the memory bound before `hello` are the session's, so
  # every carrier keeps the same ones. Bandit buffers every FIN=0 fragment of a
  # message with no bound on the total, before the prelude is even read;
  # counting shared binaries against the heap makes that buffer count too.
  defp socket_options do
    [
      compress: false,
      max_frame_size: @max_frame_size,
      timeout: Session.idle_timeout_ms(),
      max_heap_size: Session.unauthenticated_heap_cap()
    ]
  end

  # The session counts pairing failures per peer, so a noisy peer is refused
  # alone and the window stays open: a WebSocket's peer is its source address.
  defp handler_state(conn, opts) do
    max_media_bytes = Keyword.get(opts, :max_media_bytes, @default_max_media_bytes)

    opts
    |> Map.new()
    |> Map.put(:authenticated_max_heap_size, Session.authenticated_heap_cap(max_media_bytes))
    |> Map.put(:peer, conn.remote_ip)
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
