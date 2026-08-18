defmodule FermixCore.Transcription.WsSocketTest do
  # async: true — the callbacks under test are pure functions over the socket's
  # own state; nothing here reads or writes global state.
  use ExUnit.Case, async: true

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
