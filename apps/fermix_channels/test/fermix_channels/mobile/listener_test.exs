defmodule FermixChannels.Mobile.ListenerTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.Listener

  defmodule ShortDeadline do
    @moduledoc false
    # The listener's transport with the upgrade deadline cut to a fifth of a
    # second, so a test outlasts it without waiting out the real one.
    @behaviour ThousandIsland.Transport

    alias FermixChannels.Mobile.TlsTransport

    @impl true
    def handshake(socket) do
      :ok = TlsTransport.start_upgrade_deadline(200)
      TlsTransport.handshake(socket, TlsTransport.handshake_timeout_ms())
    end

    @impl true
    defdelegate listen(port, options), to: TlsTransport
    @impl true
    defdelegate accept(listener_socket), to: TlsTransport
    @impl true
    defdelegate upgrade(socket, options), to: TlsTransport
    @impl true
    defdelegate controlling_process(socket, pid), to: TlsTransport
    @impl true
    defdelegate recv(socket, length, timeout), to: TlsTransport
    @impl true
    defdelegate send(socket, data), to: TlsTransport
    @impl true
    defdelegate sendfile(socket, filename, offset, length), to: TlsTransport
    @impl true
    defdelegate getopts(socket, options), to: TlsTransport
    @impl true
    defdelegate setopts(socket, options), to: TlsTransport
    @impl true
    defdelegate shutdown(socket, way), to: TlsTransport
    @impl true
    defdelegate close(socket), to: TlsTransport
    @impl true
    defdelegate sockname(socket), to: TlsTransport
    @impl true
    defdelegate peername(socket), to: TlsTransport
    @impl true
    defdelegate peercert(socket), to: TlsTransport
    @impl true
    defdelegate secure?(), to: TlsTransport
    @impl true
    defdelegate getstat(socket), to: TlsTransport
    @impl true
    defdelegate negotiated_protocol(socket), to: TlsTransport
    @impl true
    defdelegate connection_information(socket), to: TlsTransport
  end

  defmodule DeadlineAfterAnswer do
    @moduledoc false
    # The listener's transport with its real upgrade deadline until the
    # listener has answered, then a fifth of a second left. A deadline cut
    # short from the handshake races the handshake and the request read, so on
    # a loaded machine it closed the connection before any answer; this one
    # cannot pass before the answer is on the wire.
    @behaviour ThousandIsland.Transport

    alias FermixChannels.Mobile.TlsTransport

    @impl true
    defdelegate handshake(socket), to: TlsTransport

    @impl true
    def send(socket, data) do
      result = TlsTransport.send(socket, data)
      :ok = TlsTransport.start_upgrade_deadline(200)
      result
    end

    @impl true
    defdelegate listen(port, options), to: TlsTransport
    @impl true
    defdelegate accept(listener_socket), to: TlsTransport
    @impl true
    defdelegate upgrade(socket, options), to: TlsTransport
    @impl true
    defdelegate controlling_process(socket, pid), to: TlsTransport
    @impl true
    defdelegate recv(socket, length, timeout), to: TlsTransport
    @impl true
    defdelegate sendfile(socket, filename, offset, length), to: TlsTransport
    @impl true
    defdelegate getopts(socket, options), to: TlsTransport
    @impl true
    defdelegate setopts(socket, options), to: TlsTransport
    @impl true
    defdelegate shutdown(socket, way), to: TlsTransport
    @impl true
    defdelegate close(socket), to: TlsTransport
    @impl true
    defdelegate sockname(socket), to: TlsTransport
    @impl true
    defdelegate peername(socket), to: TlsTransport
    @impl true
    defdelegate peercert(socket), to: TlsTransport
    @impl true
    defdelegate secure?(), to: TlsTransport
    @impl true
    defdelegate getstat(socket), to: TlsTransport
    @impl true
    defdelegate negotiated_protocol(socket), to: TlsTransport
    @impl true
    defdelegate connection_information(socket), to: TlsTransport
  end

  test "builds an isolated HTTPS Bandit listener and permits an ephemeral test port" do
    keyfile = Path.expand("gateway_tls_key.pem", System.tmp_dir!())
    certfile = Path.expand("gateway_tls_cert.pem", System.tmp_dir!())

    assert {:ok, options} =
             Listener.options(
               bind: {127, 0, 0, 1},
               port: 0,
               keyfile: keyfile,
               certfile: certfile,
               identity: identity(keyfile, certfile),
               router_opts: [device_registry: :registry]
             )

    assert options[:scheme] == :https
    assert options[:ip] == {127, 0, 0, 1}
    assert options[:port] == 0
    assert options[:keyfile] == keyfile
    assert options[:certfile] == certfile

    assert {FermixChannels.Mobile.Router, router_opts} = options[:plug]
    assert router_opts[:device_registry] == :registry
    assert router_opts[:identity_root] == identity_root(keyfile)
    assert options[:websocket_options] == [max_frame_size: 65_535 + 14, compress: false]
  end

  # SEC-2: ThousandIsland's defaults are 100 acceptors of 16,384 connections
  # each and a 60 s read timeout, all before any authentication.
  test "bounds concurrent connections and a slow request before the upgrade" do
    assert {:ok, options} =
             Listener.options(
               keyfile: "/tmp/key.pem",
               certfile: "/tmp/cert.pem",
               identity: identity("/tmp/key.pem", "/tmp/cert.pem")
             )

    island = options[:thousand_island_options]
    assert island[:num_acceptors] * island[:num_connections] == 64
    assert island[:read_timeout] == 10_000
    # R1-1: the stock TLS transport's handshake has no timeout, so a silent
    # peer held one of those 64 slots until it hung up.
    assert island[:transport_module] == FermixChannels.Mobile.TlsTransport

    # R3-1: Bandit's defaults keep a connection alive for any number of
    # requests, each with a 10,000-byte line and 50 headers of 10,000 bytes,
    # so a peer that kept asking held its slot for good. HTTP/2 idles in
    # between frames where no read bounds it, and no phone speaks it.
    assert options[:http_1_options] == [
             max_requests: 1,
             max_request_line_length: 2_048,
             max_header_length: 4_096,
             max_header_count: 32
           ]

    assert options[:http_2_options] == [enabled: false]
  end

  test "passes only the identity root to sockets, never gateway private key bytes" do
    assert {:ok, options} =
             Listener.options(
               bind: {127, 0, 0, 1},
               port: 0,
               keyfile: "/tmp/key.pem",
               certfile: "/tmp/cert.pem",
               identity: identity("/tmp/key.pem", "/tmp/cert.pem"),
               router_opts: [device_registry: :registry]
             )

    assert {FermixChannels.Mobile.Router, router_opts} = options[:plug]

    assert router_opts[:identity_root] == "/"
    refute Keyword.has_key?(router_opts, :gateway_keypair)
    refute inspect(router_opts) =~ Base.encode16(<<1::256>>)
  end

  test "rejects relative key paths and invalid ports" do
    assert {:error, {:invalid_path, :keyfile}} =
             Listener.options(keyfile: "key.pem", certfile: "/tmp/cert.pem")

    assert {:error, {:invalid_port, -1}} =
             Listener.options(keyfile: "/tmp/key.pem", certfile: "/tmp/cert.pem", port: -1)
  end

  test "starts TLS on an OS-assigned port without touching a fixed port" do
    root =
      Path.join(
        System.tmp_dir!(),
        "fermix-mobile-listener-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)
    assert {:ok, _identity} = Identity.ensure(root: root)

    listener =
      start_supervised!({Listener, root: root, bind: {127, 0, 0, 1}, port: 0})

    assert {:ok, {{127, 0, 0, 1}, port}} = Listener.listener_info(listener)
    assert port > 0
  end

  test "a dangling identity symlink fails closed instead of looking like a fresh install" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("mobile-listener-dangling-identity")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)
    mobile_dir = Path.join(root, "mobile")
    File.mkdir_p!(mobile_dir)
    File.chmod!(mobile_dir, 0o700)
    File.ln_s!(Path.join(root, "missing-key"), Path.join(mobile_dir, "gateway_key"))

    # The designed stop is an init refusal, so the linked starter must trap the
    # exit to read it instead of dying with the listener it just refused to run.
    Process.flag(:trap_exit, true)

    assert {:error, {:mobile_identity_unavailable, {:identity_incomplete, missing}}} =
             Listener.start_link(name: nil, root: root)

    assert Enum.sort(missing) ==
             Enum.sort([Path.join(mobile_dir, "tls.crt"), Path.join(mobile_dir, "tls.key")])
  end

  describe "an address it cannot bind" do
    setup do
      root = FermixTestSupport.SafeRm.make_tmp_dir!("mobile-listener-unavailable")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)
      assert {:ok, _identity} = Identity.ensure(root: root)

      test_pid = self()
      clock = start_supervised!({Agent, fn -> 0 end})

      seams = [
        clock: fn -> Agent.get(clock, & &1) end,
        schedule_retry: fn message, delay ->
          send(test_pid, {:retry_armed, message, delay})
          make_ref()
        end
      ]

      %{root: root, clock: clock, seams: seams}
    end

    # STB-6: the Tailscale address the settings footer suggests is often not up
    # yet at login. A listener that cannot bind must not stop, because its stop
    # escalates through the channels supervisor and halts the whole daemon.
    test "starts unavailable with the reason and retries instead of stopping", ctx do
      {listener, log} = start_unavailable(ctx, bind: {192, 0, 2, 1})

      assert Listener.status(listener) == {:unavailable, :address_unavailable}
      assert {:error, :not_listening} = Listener.listener_info(listener)
      assert log =~ "mobile listener could not listen"
      assert_receive {:retry_armed, {:retry_listen, _token}, 1_000}
    end

    test "backs off from one second, doubling to a minute", ctx do
      {listener, _log} = start_unavailable(ctx, bind: {192, 0, 2, 1})

      delays =
        for _attempt <- 1..9 do
          assert_receive {:retry_armed, {:retry_listen, _token} = retry, delay}
          ExUnit.CaptureLog.capture_log(fn -> send_and_sync(listener, retry) end)
          delay
        end

      assert delays == [1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 60_000, 60_000, 60_000]
    end

    test "gives up after a day and stays unavailable until the next boot", ctx do
      {listener, _log} = start_unavailable(ctx, bind: {192, 0, 2, 1})
      assert_receive {:retry_armed, retry, _delay}
      Agent.update(ctx.clock, fn _ -> 24 * 3_600_000 end)

      log = ExUnit.CaptureLog.capture_log(fn -> send_and_sync(listener, retry) end)

      assert log =~ "stopped retrying"
      refute_receive {:retry_armed, _retry, _delay}
      assert Listener.status(listener) == {:unavailable, :address_unavailable}
    end

    test "a retry that binds serves the port", ctx do
      {:ok, blocker} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, reuseaddr: false)
      {:ok, port} = :inet.port(blocker)

      {listener, _log} = start_unavailable(ctx, bind: {127, 0, 0, 1}, port: port)
      assert Listener.status(listener) == {:unavailable, :address_in_use}
      assert_receive {:retry_armed, retry, 1_000}

      :ok = :gen_tcp.close(blocker)
      send_and_sync(listener, retry)

      assert {:listening, {{127, 0, 0, 1}, ^port}} = Listener.status(listener)
    end

    test "a listener that dies while serving retries instead of stopping", ctx do
      listener =
        start_supervised!(
          {Listener, [root: ctx.root, bind: {127, 0, 0, 1}, port: 0] ++ ctx.seams}
        )

      assert {:listening, _address} = Listener.status(listener)
      bandit = :sys.get_state(listener).bandit

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Process.exit(bandit, :kill)
          assert_receive {:retry_armed, retry, 1_000}
          assert Listener.status(listener) == {:unavailable, :listen_failed}
          send_and_sync(listener, retry)
        end)

      assert log =~ "mobile listener stopped serving"
      assert Process.alive?(listener)
      assert {:listening, _address} = Listener.status(listener)
    end
  end

  # R3-1: Bandit reads a request with a timeout per read that every byte
  # resets, so a peer that kept talking HTTP instead of upgrading held one of
  # the 64 slots for as long as it liked.
  describe "the HTTP phase before the upgrade" do
    setup do
      root = FermixTestSupport.SafeRm.make_tmp_dir!("mobile-listener-http-phase")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)
      assert {:ok, identity} = Identity.ensure(root: root)
      %{root: root, identity: identity}
    end

    test "a request that is not an upgrade gets one answer, then the connection closes", ctx do
      listener = start_supervised!({Listener, root: ctx.root, bind: {127, 0, 0, 1}, port: 0})
      assert {:ok, {{127, 0, 0, 1}, port}} = Listener.listener_info(listener)
      socket = connect(port)

      request = "GET /healthz HTTP/1.1\r\nhost: mac\r\nconnection: keep-alive\r\n\r\n"
      :ok = :ssl.send(socket, request <> request)

      received = receive_until_closed(socket, "")
      assert length(String.split(received, "HTTP/1.1 200")) == 2
    end

    test "a request whose headers never end is closed at the upgrade deadline", ctx do
      port = start_short_deadline_listener(ctx.identity, ShortDeadline)
      socket = connect(port)

      :ok = :ssl.send(socket, "GET /healthz HTTP/1.1\r\nhost: mac\r\n")

      assert receive_until_closed(socket, "") == ""
    end

    # Bandit drains an unread request body before it closes a keep-alive
    # connection, and reads every timeout in a chunked body as no bytes yet, so
    # a body that never ends held the connection with no bound at all. The
    # answer is what shows the drain began, so the deadline runs out after it.
    test "a keep-alive request whose body never ends is closed at the upgrade deadline", ctx do
      port = start_short_deadline_listener(ctx.identity, DeadlineAfterAnswer)
      socket = connect(port)

      :ok =
        :ssl.send(
          socket,
          "POST /healthz HTTP/1.1\r\nhost: mac\r\ntransfer-encoding: chunked\r\n\r\n"
        )

      assert receive_until_closed(socket, "") =~ "HTTP/1.1 404"
    end
  end

  defp start_short_deadline_listener(identity, transport) do
    assert {:ok, options} =
             Listener.options(
               bind: {127, 0, 0, 1},
               port: 0,
               keyfile: identity.tls_key_path,
               certfile: identity.tls_cert_path,
               identity: identity
             )

    options = put_in(options, [:thousand_island_options, :transport_module], transport)
    server = start_supervised!({Bandit, options})
    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    port
  end

  defp connect(port) do
    assert {:ok, socket} =
             :ssl.connect(~c"127.0.0.1", port, [:binary, active: true, verify: :verify_none])

    socket
  end

  # Everything the listener sends until it closes the connection. A listener
  # that keeps the connection open past this test's wait fails the test.
  defp receive_until_closed(socket, received) do
    receive do
      {:ssl, ^socket, data} -> receive_until_closed(socket, received <> data)
      {:ssl_closed, ^socket} -> received
    after
      5_000 -> flunk("the listener kept the connection open; received #{inspect(received)}")
    end
  end

  defp start_unavailable(ctx, listen) do
    ExUnit.CaptureLog.with_log(fn ->
      start_supervised!({Listener, [root: ctx.root] ++ listen ++ ctx.seams})
    end)
  end

  defp send_and_sync(listener, message) do
    send(listener, message)
    _state = :sys.get_state(listener)
    :ok
  end

  defp identity(keyfile, certfile) do
    %Identity{
      gateway_private_key: <<1::256>>,
      gateway_public_key: <<2::256>>,
      tls_private_key: :unused,
      tls_certificate: :unused,
      tls_fingerprint: <<3::256>>,
      tls_key_path: keyfile,
      tls_cert_path: certfile
    }
  end

  defp identity_root(keyfile), do: keyfile |> Path.dirname() |> Path.dirname()
end
