defmodule FermixChannels.Mobile.Router do
  @moduledoc """
  The intentionally small HTTP surface for the iOS companion listener.

  Only liveness and WebSocket upgrade routes exist. All application messages
  travel inside the authenticated Noise session after upgrade.
  """

  @behaviour Plug

  import Plug.Conn

  alias FermixChannels.Mobile.SocketHandler

  @socket_options [compress: false, max_frame_size: 65_535, timeout: 50_000]

  @impl true
  @spec init(keyword()) :: keyword()
  def init(opts) when is_list(opts), do: opts

  @impl true
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{method: "GET", path_info: ["healthz"]} = conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{fermix: "mobile", v: 1}))
  end

  def call(%Plug.Conn{method: "GET", path_info: ["ws"]} = conn, opts) do
    if websocket_upgrade?(conn) do
      WebSockAdapter.upgrade(conn, SocketHandler, Map.new(opts), @socket_options)
    else
      conn |> put_resp_header("upgrade", "websocket") |> send_resp(426, "upgrade required")
    end
  end

  def call(%Plug.Conn{} = conn, _opts), do: send_resp(conn, 404, "not found")

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
