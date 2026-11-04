defmodule FermixCore.Cues.Source.Stream.SocketTest do
  # The real WebSocket transport against a TLS WebSocket peer on loopback that
  # the test drives byte by byte (`FermixTestSupport.WebSocketPeer`): no outside
  # network. The peer's certificate names stream.example.test and is signed by
  # a throwaway root the socket is handed as `:cacerts`. The address check is
  # replaced by one answering 127.0.0.1 for that name, so the dial goes to the
  # loopback address while SNI, the certificate check and `Host` carry the name:
  # a connection that completes proves the pin.
  #
  # `start/3` hands back a monitor taken before the socket can exit, so each
  # test owns the socket's exit from the start.
  use ExUnit.Case, async: true

  alias FermixCore.Cues.Source.Stream.Socket
  alias FermixCore.Net.Egress
  alias FermixTestSupport.WebSocketPeer, as: Peer

  @wait_ms 10_000
  @short_handshake_ms 200
  @host "stream.example.test"
  @max_frame_bytes 1_024
  @window 64
  @loopback {127, 0, 0, 1}

  setup do
    listener = Peer.listen()
    %{listener: listener, url: "wss://#{@host}:#{listener.port}/v1/news?feed=all"}
  end

  describe "connecting" do
    test "the upgrade carries the headers to the URL's path, its name in SNI and Host, " <>
           "at the address the check answered",
         ctx do
      test = self()
      peer = Peer.accept(ctx.listener)
      headers = [{"APCA-API-KEY-ID", "key-7f3a1c"}, {"APCA-API-SECRET-KEY", "secret-91c2e8"}]

      guard = fn url ->
        send(test, {:guarded, url})
        {:ok, @loopback}
      end

      {socket, _monitor} = start(ctx, headers: headers, guard: guard)
      assert_receive {:guarded, url}, @wait_ms
      assert url == ctx.url

      assert_receive {:ws_peer, ^peer, {:upgrade, request}}, @wait_ms
      assert request.target == "/v1/news?feed=all"
      assert request.sni == @host
      assert {"host", "#{@host}:#{ctx.listener.port}"} in request.headers
      assert {"apca-api-key-id", "key-7f3a1c"} in request.headers
      assert {"apca-api-secret-key", "secret-91c2e8"} in request.headers
      assert_receive {:cue_stream, ^socket, :connected}, @wait_ms
    end

    # The messages are written in the handshake, before `:connected` is sent, so
    # they are the first frames the peer reads, in order, ahead of anything the
    # owner sends once it hears `:connected`.
    test "the messages follow the upgrade in order, before the owner hears :connected", ctx do
      peer = Peer.accept(ctx.listener)
      auth = ~s({"action":"auth","key":"key-7f3a1c","secret":"secret-91c2e8"})
      subscribe = ~s({"action":"subscribe","news":["*"]})

      {socket, _monitor} = start(ctx, messages: [auth, subscribe])
      assert_receive {:cue_stream, ^socket, :connected}, @wait_ms
      :ok = Socket.ping(socket)

      for expected <- [{:text, auth}, {:text, subscribe}, {:ping, ""}] do
        assert_receive {:ws_peer, ^peer, {:frame, opcode, payload}}, @wait_ms
        assert {opcode, payload} == expected
      end
    end

    test "an upgrade answered with anything but 101 ends with that status; no redirect is followed",
         ctx do
      for status <- [401, 302] do
        _peer = Peer.accept(ctx.listener, answer: status)
        {socket, monitor} = start(ctx)

        assert_receive {:DOWN, ^monitor, :process, ^socket, {:upgrade_refused, ^status}}, @wait_ms
        refute_received {:cue_stream, ^socket, :connected}
      end
    end

    test "an address the guard refuses ends the socket before any dial", ctx do
      for answer <- [{10, 0, 0, 7}, {169, 254, 169, 254}, @loopback, {100, 64, 0, 9}] do
        # The production check, Net.Guard, with only its lookup replaced.
        resolver = fn @host -> {:ok, [answer]} end
        {:ok, socket, monitor} = Socket.start(ctx.url, self(), base_opts(resolver: resolver))

        assert_receive {:DOWN, ^monitor, :process, ^socket, :address_refused}, @wait_ms
      end
    end

    # No seam at all: the production check refuses these literals before any
    # lookup or dial, and the refusal comes at once, which the monitor
    # `start/3` returns still sees.
    test "an IP literal the production check refuses ends the socket at once" do
      for url <- ["wss://10.0.0.7/v1/news", "wss://127.0.0.1:4443/v1/news"] do
        {:ok, socket, monitor} = Socket.start(url, self(), base_opts([]))

        assert_receive {:DOWN, ^monitor, :process, ^socket, :address_refused}, @wait_ms
      end
    end

    test "a route the proxy would carry, or a URL with no host, is refused without a process" do
      proxied = Egress.new(proxy: "http://proxy.example.test:3128")

      assert Socket.start("wss://#{@host}/v1/news", self(), base_opts(egress: proxied)) ==
               {:error, :proxy_unsupported_transport}

      assert Socket.start("wss:///v1/news", self(), base_opts([])) == {:error, :url_without_host}
    end

    test "a certificate the OS trust store does not vouch for is refused at TLS", ctx do
      peer = Peer.accept(ctx.listener)
      {socket, monitor} = start(ctx, [], [:cacerts])

      assert_receive {:DOWN, ^monitor, :process, ^socket,
                      {:connect_failed, {:tls_alert, {:unknown_ca, _detail}}}},
                     @wait_ms

      assert_receive {:ws_peer, ^peer, {:tls_failed, _reason}}, @wait_ms
    end

    test "the name is still checked when the dial goes to an address", ctx do
      other = Peer.listen(name: "other.example.test")
      _peer = Peer.accept(other)
      url = "wss://#{@host}:#{other.port}/v1/news"
      {socket, monitor} = start(%{ctx | url: url, listener: other})

      assert_receive {:DOWN, ^monitor, :process, ^socket,
                      {:connect_failed, {:tls_alert, _alert}}},
                     @wait_ms
    end

    test "a handshake that never finishes ends at :handshake_timeout", ctx do
      _peer = Peer.accept(ctx.listener, answer: :no_tls)
      {socket, monitor} = start(ctx, handshake_timeout: @short_handshake_ms)

      assert_receive {:DOWN, ^monitor, :process, ^socket, {:connect_failed, :timeout}}, @wait_ms
    end
  end

  describe "the frame cap" do
    test "a frame announcing more than the cap ends the socket before the rest of it arrives",
         ctx do
      %{socket: socket, monitor: monitor, peer: peer} = connect(ctx)

      # A megabyte announced, a hundred bytes of it sent, and nothing more ever.
      Peer.send_raw(peer, Peer.frame(:text, String.duplicate("a", 100), length: 1_000_000))

      assert_receive {:DOWN, ^monitor, :process, ^socket, :frame_too_large}, @wait_ms
      assert_receive {:ws_peer, ^peer, {:frame, :close, <<1009::16>>}}, @wait_ms
      refute_received {:cue_stream, ^socket, {:frame, _frame}}
    end

    test "a frame of exactly the cap is forwarded", ctx do
      %{socket: socket, peer: peer} = connect(ctx)
      payload = String.duplicate("c", @max_frame_bytes)

      Peer.send_raw(peer, Peer.frame(:binary, payload))

      assert_receive {:cue_stream, ^socket, {:frame, {:binary, ^payload}}}, @wait_ms
    end

    test "the fragments of a message count together, and end it before the message is whole",
         ctx do
      %{socket: socket, monitor: monitor, peer: peer} = connect(ctx)

      # The first fragment and a ping, read and answered: the ping does not
      # reset what the message holds.
      Peer.send_raw(peer, [
        Peer.frame(:text, String.duplicate("b", 600), fin: false),
        Peer.frame(:ping, "beat-17")
      ])

      assert_receive {:ws_peer, ^peer, {:frame, :pong, "beat-17"}}, @wait_ms

      # The second fragment's header takes the message past the cap; ten bytes
      # of its six hundred follow, and nothing more ever.
      Peer.send_raw(peer, Peer.frame(:continuation, String.duplicate("b", 10), length: 600))

      assert_receive {:DOWN, ^monitor, :process, ^socket, :frame_too_large}, @wait_ms
      refute_received {:cue_stream, ^socket, {:frame, _frame}}
    end

    test "fragments under the cap arrive as one frame, with a ping between them answered",
         ctx do
      %{socket: socket, peer: peer} = connect(ctx)

      Peer.send_raw(peer, [
        Peer.frame(:text, "first ", fin: false),
        Peer.frame(:ping, "beat-41"),
        Peer.frame(:continuation, "second ", fin: false),
        Peer.frame(:continuation, "third")
      ])

      assert_receive {:ws_peer, ^peer, {:frame, :pong, "beat-41"}}, @wait_ms
      assert_receive {:cue_stream, ^socket, {:frame, {:text, "first second third"}}}, @wait_ms
    end

    # A control frame counts against RFC 6455's 125 bytes, never the message's
    # cap: this message is exactly the cap, and the ping sits inside it.
    test "a 125-byte ping between fragments of a message at the cap refuses nothing", ctx do
      %{socket: socket, peer: peer} = connect(ctx)
      beat = String.duplicate("p", 125)

      Peer.send_raw(peer, [
        Peer.frame(:text, String.duplicate("d", 1_000), fin: false),
        Peer.frame(:ping, beat),
        Peer.frame(:continuation, String.duplicate("d", @max_frame_bytes - 1_000))
      ])

      assert_receive {:ws_peer, ^peer, {:frame, :pong, ^beat}}, @wait_ms
      text = String.duplicate("d", @max_frame_bytes)
      assert_receive {:cue_stream, ^socket, {:frame, {:text, ^text}}}, @wait_ms
    end
  end

  # Text that is not UTF-8, and a ping longer than RFC 6455 allows: the socket
  # closes with 1002 and ends as if the peer had closed it.
  test "a peer that breaks the protocol ends the socket with no close code", ctx do
    for bad <- [
          Peer.frame(:text, <<0xFF, 0xFE, 0xFD>>),
          Peer.frame(:ping, String.duplicate("p", 126))
        ] do
      %{socket: socket, monitor: monitor, peer: peer} = connect(ctx)

      Peer.send_raw(peer, bad)

      assert_receive {:ws_peer, ^peer, {:frame, :close, <<1002::16>>}}, @wait_ms
      assert_receive {:DOWN, ^monitor, :process, ^socket, {:remote_closed, nil}}, @wait_ms
    end
  end

  test "at most 64 frames run ahead of the owner's acknowledgements", ctx do
    %{socket: socket, peer: peer} = connect(ctx)

    # One write, so one TLS record and one read: the socket decodes all hundred
    # in one pass, and a socket without a window would forward every one of
    # them in that same pass, ahead of anything the test does next.
    Peer.send_raw(peer, Enum.map(1..100, &Peer.frame(:text, "item-#{&1}")))

    for n <- 1..@window, do: assert_item(socket, n)
    refute_received {:cue_stream, ^socket, {:frame, _frame}}

    :ok = Socket.ack(socket)
    assert_item(socket, 65)
    refute_received {:cue_stream, ^socket, {:frame, _frame}}

    for _n <- 66..100, do: :ok = Socket.ack(socket)
    for n <- 66..100, do: assert_item(socket, n)

    # With the window open again the socket reads the next frame.
    for _n <- 1..@window, do: :ok = Socket.ack(socket)
    Peer.send_raw(peer, Peer.frame(:text, "item-101"))
    assert_item(socket, 101)
  end

  describe "pings" do
    test "a server ping is answered with its payload", ctx do
      %{peer: peer} = connect(ctx)

      Peer.send_raw(peer, Peer.frame(:ping, "beat-9"))

      assert_receive {:ws_peer, ^peer, {:frame, :pong, "beat-9"}}, @wait_ms
    end

    test "ping/1 asks the peer, and its pong reaches the owner", ctx do
      %{socket: socket, peer: peer} = connect(ctx)

      :ok = Socket.ping(socket)
      assert_receive {:ws_peer, ^peer, {:frame, :ping, ""}}, @wait_ms

      Peer.send_raw(peer, Peer.frame(:pong, ""))
      assert_receive {:cue_stream, ^socket, :pong}, @wait_ms
    end
  end

  # Slack's Socket Mode client acknowledges each envelope with a text frame.
  describe "writing" do
    test "send_text/2 writes text frames in order with the other writes", ctx do
      %{socket: socket, peer: peer} = connect(ctx)

      :ok = Socket.send_text(socket, ~s({"envelope_id":"env-1"}))
      :ok = Socket.ping(socket)
      :ok = Socket.send_text(socket, ~s({"envelope_id":"env-2"}))

      for expected <- [
            {:text, ~s({"envelope_id":"env-1"})},
            {:ping, ""},
            {:text, ~s({"envelope_id":"env-2"})}
          ] do
        assert_receive {:ws_peer, ^peer, {:frame, opcode, payload}}, @wait_ms
        assert {opcode, payload} == expected
      end
    end
  end

  describe "closing" do
    test "close/1 sends a close frame and exits :normal once the peer answers", ctx do
      %{socket: socket, monitor: monitor, peer: peer} = connect(ctx)

      :ok = Socket.close(socket)
      assert_receive {:ws_peer, ^peer, {:frame, :close, <<1000::16>>}}, @wait_ms

      Peer.send_raw(peer, Peer.frame(:close, <<1000::16>>))
      assert_receive {:DOWN, ^monitor, :process, ^socket, :normal}, @wait_ms
      assert_receive {:ws_peer, ^peer, :closed}, @wait_ms
    end

    test "close/1 waits a bounded time for a peer that never answers, then exits :normal", ctx do
      %{socket: socket, monitor: monitor, peer: peer} = connect(ctx)

      :ok = Socket.close(socket)
      assert_receive {:ws_peer, ^peer, {:frame, :close, <<1000::16>>}}, @wait_ms

      # The wait's expiry, delivered by hand rather than waited for.
      send(socket, :close_wait_over)
      assert_receive {:DOWN, ^monitor, :process, ^socket, :normal}, @wait_ms
    end

    test "closes when its owner is gone", ctx do
      test = self()
      peer = Peer.accept(ctx.listener)

      # The owner starts the socket, so the returned monitor is the owner's; the
      # test takes its own before the owner is told to go, which is the only
      # thing that ends this socket. Linked, so the owner ends with the test.
      owner =
        spawn_link(fn ->
          {:ok, socket, _monitor} = Socket.start(ctx.url, self(), loopback_opts(ctx, []))
          send(test, {:socket, socket})

          receive do
            {:cue_stream, ^socket, :connected} -> send(test, :connected)
          end

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:socket, socket}, @wait_ms
      monitor = Process.monitor(socket)
      assert_receive :connected, @wait_ms

      send(owner, :stop)
      assert_receive {:ws_peer, ^peer, {:frame, :close, <<1000::16>>}}, @wait_ms
      Peer.send_raw(peer, Peer.frame(:close, <<1000::16>>))
      assert_receive {:DOWN, ^monitor, :process, ^socket, :normal}, @wait_ms
    end

    # Seventy frames and a close in one write, so one read: the window takes
    # 64 and six wait in the queue when the close ends the connection.
    test "frames still queued past the window reach the owner before a peer close ends it",
         ctx do
      %{socket: socket, monitor: monitor, peer: peer} = connect(ctx)
      frames = Enum.map(1..70, &Peer.frame(:text, "item-#{&1}"))

      Peer.send_raw(peer, frames ++ [Peer.frame(:close, <<1001::16>>)])

      assert_receive {:DOWN, ^monitor, :process, ^socket, {:remote_closed, 1001}}, @wait_ms
      # What a process sends before it exits arrives before its :DOWN.
      for n <- 1..70, do: assert_item_received(socket, n)
    end

    # Mint reads a close frame with no payload as a normal close.
    test "a close with an empty payload is answered and ends the socket as 1000", ctx do
      %{socket: socket, monitor: monitor, peer: peer} = connect(ctx)

      Peer.send_raw(peer, Peer.frame(:close, ""))

      assert_receive {:ws_peer, ^peer, {:frame, :close, <<1000::16>>}}, @wait_ms
      assert_receive {:DOWN, ^monitor, :process, ^socket, {:remote_closed, 1000}}, @wait_ms
    end

    test "a close from the peer is answered and ends the socket with its code", ctx do
      %{socket: socket, monitor: monitor, peer: peer} = connect(ctx)

      Peer.send_raw(peer, Peer.frame(:close, <<1001::16, "going away">>))

      assert_receive {:ws_peer, ^peer, {:frame, :close, <<1001::16>>}}, @wait_ms
      assert_receive {:DOWN, ^monitor, :process, ^socket, {:remote_closed, 1001}}, @wait_ms
    end

    test "a connection dropped without a close frame ends with no code", ctx do
      %{socket: socket, monitor: monitor, peer: peer} = connect(ctx)

      Peer.close_tcp(peer)

      assert_receive {:DOWN, ^monitor, :process, ^socket, {:remote_closed, nil}}, @wait_ms
    end
  end

  defp assert_item(socket, n) do
    text = "item-#{n}"
    assert_receive {:cue_stream, ^socket, {:frame, {:text, ^text}}}, @wait_ms
  end

  defp assert_item_received(socket, n) do
    text = "item-#{n}"
    assert_received {:cue_stream, ^socket, {:frame, {:text, ^text}}}
  end

  defp base_opts(opts) do
    Keyword.merge(
      [handshake_timeout: @wait_ms, max_frame_bytes: @max_frame_bytes, egress: %Egress{}],
      opts
    )
  end

  # The options of a socket whose address check answers the loopback address
  # and which trusts the peer's throwaway root.
  defp loopback_opts(ctx, opts, without \\ []) do
    [cacerts: ctx.listener.cacerts, guard: fn _url -> {:ok, @loopback} end]
    |> Keyword.drop(without)
    |> Keyword.merge(opts)
    |> base_opts()
  end

  # A started socket and the monitor `start/3` took for the test.
  defp start(ctx, opts \\ [], without \\ []) do
    {:ok, socket, monitor} = Socket.start(ctx.url, self(), loopback_opts(ctx, opts, without))
    {socket, monitor}
  end

  # A connected socket, its monitor, and the peer that took it.
  defp connect(ctx) do
    peer = Peer.accept(ctx.listener)
    {socket, monitor} = start(ctx)
    assert_receive {:ws_peer, ^peer, {:upgrade, _request}}, @wait_ms
    assert_receive {:cue_stream, ^socket, :connected}, @wait_ms
    %{socket: socket, monitor: monitor, peer: peer}
  end
end

defmodule FermixCore.Cues.Source.Stream.SocketLogTest do
  # async: false — it asserts what the log does not contain, and another
  # test's output would land in the same capture.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Cues.Source.Stream.Socket
  alias FermixCore.Net.Egress

  @wait_ms 10_000

  test "a transport that crashes before its upgrade logs no header or message value" do
    headers = [{"APCA-API-KEY-ID", "key-5d0e2b"}, {"APCA-API-SECRET-KEY", "secret-c48a19"}]
    messages = [~s({"action":"auth","key":"key-90af3e","secret":"secret-27bd64"})]

    log =
      capture_log(fn ->
        {:ok, socket, monitor} =
          Socket.start("wss://stream.example.test/v1/news", self(),
            handshake_timeout: @wait_ms,
            max_frame_bytes: 1_024,
            egress: %Egress{},
            headers: headers,
            messages: messages,
            guard: fn _url -> raise "the address check broke" end
          )

        assert_receive {:DOWN, ^monitor, :process, ^socket, {%RuntimeError{}, _stack}}, @wait_ms
      end)

    assert log =~ "the address check broke"

    for value <- ["key-5d0e2b", "secret-c48a19", "key-90af3e", "secret-27bd64"],
        do: refute(log =~ value)
  end
end
