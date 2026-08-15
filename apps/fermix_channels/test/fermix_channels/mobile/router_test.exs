defmodule FermixChannels.Mobile.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias FermixChannels.Mobile.Router

  test "health endpoint exposes only the fixed liveness envelope" do
    conn = Router.call(conn(:get, "/healthz"), Router.init([]))

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    assert Jason.decode!(conn.resp_body) == %{"fermix" => "mobile", "v" => 1}
  end

  test "only GET healthz and GET ws are routed" do
    assert Router.call(conn(:post, "/healthz"), Router.init([])).status == 404
    assert Router.call(conn(:get, "/anything"), Router.init([])).status == 404
    assert Router.call(conn(:get, "/ws/extra"), Router.init([])).status == 404
  end

  test "ws refuses a non-upgrade request" do
    conn = Router.call(conn(:get, "/ws"), Router.init([]))

    assert conn.status == 426
    assert get_resp_header(conn, "upgrade") == ["websocket"]
  end

  test "ws upgrades with the mobile socket handler and bounded options" do
    request =
      conn(:get, "/ws")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | &1])
      |> put_req_header("connection", "upgrade")
      |> put_req_header("upgrade", "websocket")
      |> put_req_header("sec-websocket-version", "13")
      |> put_req_header("sec-websocket-key", Base.encode64(:crypto.strong_rand_bytes(16)))

    request_ref = elem(request.adapter, 1).ref
    conn = Router.call(request, Router.init(device_registry: :registry))

    assert conn.state == :upgraded

    assert_receive {^request_ref, :upgrade,
                    {:websocket, {FermixChannels.Mobile.SocketHandler, state, socket_opts}}}

    assert state.device_registry == :registry
    assert socket_opts[:compress] == false
    assert socket_opts[:max_frame_size] == 65_535
    assert socket_opts[:timeout] == 50_000
  end
end
