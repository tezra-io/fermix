defmodule FermixCore.Transcription.WsSocketTest do
  # async: true — the callbacks under test are pure functions over the socket's
  # own state; nothing here reads or writes global state.
  use ExUnit.Case, async: true

  alias FermixCore.Timeouts
  alias FermixCore.Transcription.WsSocket

  # A live handshake needs a server, which no test in this suite may open. What
  # IS testable without one is everything WebSockex routes through plain
  # functions: the frames the socket replies with, and what it forwards to its
  # parent.

  describe "start/1 argument contract" do
    test "requires url, headers and parent before it ever dials" do
      assert_raise KeyError, fn -> WsSocket.start([]) end
      assert_raise KeyError, fn -> WsSocket.start(url: "wss://example.test") end

      assert_raise KeyError, fn ->
        WsSocket.start(url: "wss://example.test", headers: [])
      end
    end
  end

  describe "start_options/2" do
    test "verifies the vendor peer instead of taking WebSockex's insecure default" do
      assert {:ok, opts} =
               WsSocket.start_options("wss://api.deepgram.com/v1/listen?model=nova-3", [
                 {"Authorization", "Token secret"}
               ])

      # Without :ssl_options WebSockex connects with verify: :verify_none, and
      # the Authorization header below goes to whoever answered.
      ssl_options = Keyword.fetch!(opts, :ssl_options)

      assert ssl_options[:verify] == :verify_peer
      assert ssl_options[:server_name_indication] == ~c"api.deepgram.com"

      assert opts[:extra_headers] == [{"Authorization", "Token secret"}]
      assert opts[:handshake_timeout] == Timeouts.transcription_ws_connect()
    end

    test "refuses a URL with no host rather than dialing a peer it cannot verify" do
      assert WsSocket.start_options("not-a-url", []) == {:error, :ws_url_without_host}
      assert WsSocket.start_options("wss:///v1/listen", []) == {:error, :ws_url_without_host}
    end
  end

  describe "frame forwarding" do
    test "forwards text and binary frames to the parent, tagged with the socket pid" do
      state = %{parent: self()}
      socket = self()

      assert {:ok, ^state} = WsSocket.handle_frame({:text, "{\"type\":\"Results\"}"}, state)
      assert_receive {:transcription_ws, ^socket, {:frame, {:text, "{\"type\":\"Results\"}"}}}

      assert {:ok, ^state} = WsSocket.handle_frame({:binary, <<1, 2, 3>>}, state)
      assert_receive {:transcription_ws, ^socket, {:frame, {:binary, <<1, 2, 3>>}}}
    end

    test "ignores frame kinds neither vendor uses" do
      state = %{parent: self()}

      assert {:ok, ^state} = WsSocket.handle_frame({:ping, ""}, state)
      refute_received {:transcription_ws, _socket, _payload}
    end
  end

  describe "casts" do
    test "a queued frame is replied onto the wire verbatim" do
      state = %{parent: self()}

      assert {:reply, {:binary, <<0, 1>>}, ^state} =
               WsSocket.handle_cast({:send_frame, {:binary, <<0, 1>>}}, state)

      assert {:reply, {:text, "hi"}, ^state} =
               WsSocket.handle_cast({:send_frame, {:text, "hi"}}, state)
    end

    test "a binary frame is acknowledged to the parent before it goes on the wire" do
      state = %{parent: self()}
      socket = self()

      assert {:reply, {:binary, <<0, 1, 2>>}, ^state} =
               WsSocket.handle_cast({:send_frame, {:binary, <<0, 1, 2>>}}, state)

      # This ack is the session's only view of this process's mailbox: it counts
      # bytes cast minus bytes acked, and a socket wedged inside a blocking send
      # stops acking altogether.
      assert_receive {:transcription_ws, ^socket, {:sent, 3}}
    end

    test "a text frame is not acknowledged — only PCM rides the in-flight window" do
      state = %{parent: self()}

      assert {:reply, {:text, "hi"}, ^state} =
               WsSocket.handle_cast({:send_frame, {:text, "hi"}}, state)

      refute_received {:transcription_ws, _socket, {:sent, _bytes}}
    end

    test "close closes the connection" do
      state = %{parent: self()}
      assert {:close, ^state} = WsSocket.handle_cast(:close, state)
    end
  end

  describe "handle_disconnect/2" do
    test "reports the disconnect to the parent and stops instead of reconnecting" do
      state = %{parent: self()}
      socket = self()

      # {:ok, state} is WebSockex's "do not reconnect" answer: reconnect policy
      # is the session's, bounded, not an invisible loop in the transport.
      assert {:ok, ^state} = WsSocket.handle_disconnect(%{reason: {:local, :normal}}, state)
      assert_receive {:transcription_ws, ^socket, {:disconnect, %{reason: {:local, :normal}}}}
    end
  end
end
