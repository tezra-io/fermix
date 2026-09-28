defmodule FermixChannels.Mobile.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias FermixChannels.Mobile.PairManager
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Mobile.Router

  test "health endpoint exposes only the fixed liveness envelope" do
    conn = Router.call(conn(:get, "/healthz"), Router.init([]))

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

    assert Jason.decode!(conn.resp_body) == %{
             "fermix" => "mobile",
             "v" => Protocol.protocol_version()
           }
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
    # The largest Noise message plus the largest masked client header (SEC-10).
    assert socket_opts[:max_frame_size] == 65_535 + 14

    # SEC-1: an unauthenticated connection is killed once its heap, the
    # fragments Bandit buffers included, outgrows a handshake's needs; an
    # attached device gets the larger cap media needs.
    word = :erlang.system_info(:wordsize)

    assert %{kill: true, include_shared_binaries: true, size: size} =
             socket_opts[:max_heap_size]

    assert size * word == 4 * 1_024 * 1_024

    assert %{kill: true, include_shared_binaries: true, size: raised} =
             state.authenticated_max_heap_size

    assert raised * word == (64 + 4 * 20) * 1_024 * 1_024

    # The upgrade precedes the prelude, so this one idle timeout also governs a
    # pairing socket: it must outlive the whole owner-approval window or a slow
    # approval kills the ceremony from underneath.
    assert socket_opts[:timeout] > PairManager.max_ttl_ms()
  end

  # SEC-8: pairing failures are counted per source address, so the socket's
  # pairing calls carry the address the connection came from.
  test "ws binds the socket's pairing calls to the connection's source address" do
    manager =
      start_supervised!(
        {PairManager,
         name: nil,
         ensure_identity: fn -> {:ok, %{gateway_public_key: <<1::256>>}} end,
         activate_listener: fn _identity -> :ok end,
         emit_pair: fn _status, _duration_us -> :ok end}
      )

    assert {:ok, window} = PairManager.open(manager)
    request = upgrade_request()
    request_ref = elem(request.adapter, 1).ref
    Router.call(request, Router.init(max_media_bytes: 1_024))

    assert_receive {^request_ref, :upgrade, {:websocket, {_handler, state, _socket_opts}}}
    assert {:ok, _window} = state.current_pair.(manager)

    for _attempt <- 1..5 do
      state.record_pair_failure.(manager, window.session_id)
    end

    assert :none = state.current_pair.(manager)
    assert :none = PairManager.current(manager, request.remote_ip)
    assert {:ok, _window} = PairManager.current(manager, {10, 0, 0, 9})

    word = :erlang.system_info(:wordsize)
    assert state.authenticated_max_heap_size.size * word == 64 * 1_024 * 1_024 + 4 * 1_024
  end

  defp upgrade_request do
    conn(:get, "/ws")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | &1])
    |> put_req_header("connection", "upgrade")
    |> put_req_header("upgrade", "websocket")
    |> put_req_header("sec-websocket-version", "13")
    |> put_req_header("sec-websocket-key", Base.encode64(:crypto.strong_rand_bytes(16)))
  end
end
