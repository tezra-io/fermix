defmodule FermixChannels.Desktop.CallBridgeTest do
  @moduledoc """
  The bridge a computer's app's `realtime.sock` is served with after a move
  (M97 §9.2): its frame mapping both ways, its refusals, a dropped link held
  and resumed, and the clean end before a move back. The bridge runs in the
  test's process, as it runs in the connection's handler; the relay is a
  stand-in that tells the test each frame it is handed (`Desktop.Relay`'s
  `open_call/2`, `send_call/5` and `close_call/2`).
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.CallBridge

  @pcm :binary.copy(<<1, 0>>, 2_400)
  @caps %{"available" => true, "min_version" => 2, "max_version" => 5, "camera" => false}

  defmodule FakeRelay do
    @moduledoc false
    use GenServer

    def start_link({test, answer}), do: GenServer.start_link(__MODULE__, {test, answer})

    @impl true
    def init({test, answer}), do: {:ok, %{test: test, answer: answer}}

    @impl true
    def handle_call({:open_call, call_id}, _from, state) do
      send(state.test, {:opened, call_id})
      {:reply, state.answer, state}
    end

    @impl true
    def handle_cast({:call_frame, _call_id, _bridge, type, fields, bytes}, state) do
      send(state.test, {:up, type, fields, bytes})
      {:noreply, state}
    end

    def handle_cast({:close_call, call_id, _bridge}, state) do
      send(state.test, {:closed, call_id})
      {:noreply, state}
    end
  end

  setup do
    %{relay: start_relay!({:ok, %{caps: @caps, name: "garden server"}})}
  end

  describe "the mapping" do
    test "call_start opens the call on the server: its open, its hello, then the start", ctx do
      bridge = open!(ctx.relay, 3)
      assert {:cont, _bridge} = CallBridge.event(bridge, event("call_start"))

      assert_receive {:opened, "call-1"}
      assert_receive {:up, "call_open", %{"resume" => false}, <<>>}
      assert_receive {:up, "call_line", hello_fields, hello}
      refute Map.has_key?(hello_fields, "control_seq")
      assert Jason.decode!(hello) == %{"type" => "client_hello", "protocol_version" => 3}
      assert_receive {:up, "call_line", %{"control_seq" => 1}, start}
      assert Jason.decode!(start) == %{"type" => "call_start"}
    end

    # M97 §3.4: a computer ahead of its server speaks the server's versions.
    test "an app newer than the server's window opens the call at the server's newest" do
      relay = start_relay!({:ok, %{caps: %{@caps | "max_version" => 4}, name: "garden server"}})
      {:cont, _bridge} = CallBridge.event(open!(relay, 5), event("call_start"))
      assert_receive {:up, "call_line", %{}, hello}
      assert %{"protocol_version" => 4} = Jason.decode!(hello)
    end

    test "the microphone goes up in whole-sample frames of at most 100 ms", ctx do
      bridge = call_up!(ctx.relay)
      chunk = @pcm <> @pcm <> <<7, 0, 9>>
      assert {:cont, _bridge} = CallBridge.event(bridge, audio(chunk))

      assert_receive {:up, "call_audio", %{}, @pcm}
      assert_receive {:up, "call_audio", %{}, @pcm}
      assert_receive {:up, "call_audio", %{}, <<7, 0>>}
      _ = :sys.get_state(ctx.relay)
      refute_received {:up, "call_audio", _fields, _bytes}
    end

    test "controls are numbered, playback reports go as they come", ctx do
      bridge = call_up!(ctx.relay)
      {:cont, bridge} = CallBridge.event(bridge, event("mute", %{"enabled" => true}))
      assert_receive {:up, "call_line", %{"control_seq" => 2}, mute}
      assert Jason.decode!(mute) == %{"type" => "mute", "enabled" => true}

      progress = %{"playback_id" => "m1", "played_ms" => 100, "drained" => false}
      {:cont, _bridge} = CallBridge.event(bridge, event("playback_progress", progress))
      assert_receive {:up, "call_line", fields, report}
      refute Map.has_key?(fields, "control_seq")
      assert Jason.decode!(report) == Map.put(progress, "type", "playback_progress")
    end

    test "down, the server's hello is the call's, its lines go as they are, its audio as audio_delta",
         ctx do
      bridge = call_up!(ctx.relay)

      {:cont, bridge} = down(bridge, "call_line", ~s({"type":"server_hello","min_version":1}))
      refute_received {:app, _line}

      {:cont, bridge} = down(bridge, "call_line", ~s({"type":"state","state":"listening"}))
      assert_received {:app, ~s({"type":"state","state":"listening"})}

      {:cont, _bridge} = down(bridge, "call_audio", @pcm, %{"playback_id" => "m1"})
      assert_received {:app, delta}

      assert Jason.decode!(delta) == %{
               "type" => "audio_delta",
               "audio" => Base.encode64(@pcm),
               "playback_id" => "m1"
             }
    end

    test "a hang-up keeps the connection for a fresh call under a new id", ctx do
      bridge = call_up!(ctx.relay)
      {:cont, bridge} = CallBridge.event(bridge, event("call_stop"))
      assert_receive {:up, "call_line", %{"control_seq" => 2}, _stop}

      {:cont, bridge} = down(bridge, "call_line", ~s({"type":"state","state":"idle"}))
      assert {:cont, bridge} = down(bridge, "call_close", <<>>, %{"reason" => "ended"})
      assert_receive {:closed, "call-1"}

      {:cont, _bridge} = CallBridge.event(bridge, event("call_start"))
      assert_receive {:opened, "call-2"}
    end

    test "an end after an error line closes the connection, as the local socket does", ctx do
      bridge = call_up!(ctx.relay)
      {:cont, bridge} = down(bridge, "call_line", ~s({"type":"error","reason":"session_down"}))
      assert {:stop, _bridge} = down(bridge, "call_close", <<>>, %{"reason" => "ended"})
      assert_receive {:closed, "call-1"}
    end

    # The one error line that leaves a call up.
    test "camera_off is passed on and the call goes on", ctx do
      bridge = call_up!(ctx.relay)
      {:cont, bridge} = down(bridge, "call_line", ~s({"type":"error","reason":"camera_off"}))
      {:cont, bridge} = down(bridge, "call_line", ~s({"type":"state","state":"idle"}))
      assert {:cont, _bridge} = down(bridge, "call_close", <<>>, %{"reason" => "ended"})
    end

    test "the app leaving ends the call on the server", ctx do
      bridge = call_up!(ctx.relay)
      assert :ok = CallBridge.close(bridge)
      assert_receive {:up, "call_close", %{"reason" => "app_closed"}, <<>>}
      assert_receive {:closed, "call-1"}
    end
  end

  describe "refusals" do
    test "each relay refusal is an error with the engine's sentence, and the connection closes" do
      for {answer, reason} <- [
            {{:error, {:unreachable, "The server garden server is unreachable."}},
             "server_unreachable"},
            {{:error, {:revoked, "The server garden server does not know this computer."}},
             "desktop_revoked"},
            {{:error, :not_taken}, "server_too_old"},
            {{:error, :busy}, "busy"}
          ] do
        relay = start_relay!(answer)
        assert {:stop, _bridge} = CallBridge.event(open!(relay, 3), event("call_start"))
        assert_received {:app_event, %{type: "error", reason: ^reason, sentence: sentence}}
        assert is_binary(sentence) and sentence != ""
        _ = :sys.get_state(relay)
        refute_received {:up, _type, _fields, _bytes}
      end
    end

    # The server's playback credit needs a report for every engine, which an
    # app below version 3 cannot send.
    test "an app below version 3 is told to update before anything is opened", ctx do
      assert {:stop, _bridge} = CallBridge.event(open!(ctx.relay, 2), event("call_start"))

      assert_received {:app_event,
                       %{type: "error", reason: "unsupported_protocol_version", min_version: 3}}

      refute_received {:opened, _id}
    end

    test "a control with no call is not_connected; a hang-up with none is idle", ctx do
      bridge = open!(ctx.relay, 3)
      assert {:cont, bridge} = CallBridge.event(bridge, event("call_stop"))
      assert_received {:app_event, %{type: "state", state: "idle"}}
      assert {:cont, bridge} = CallBridge.event(bridge, audio(@pcm))
      assert {:stop, _bridge} = CallBridge.event(bridge, event("mute", %{"enabled" => true}))
      assert_received {:app_event, %{type: "error", reason: "not_connected"}}
    end

    test "a call the server no longer holds is said, and closes the connection", ctx do
      bridge = call_up!(ctx.relay)
      assert {:stop, _bridge} = down(bridge, "call_close", <<>>, %{"reason" => "unknown_call"})
      assert_received {:app_event, %{type: "error", reason: "call_ended", sentence: sentence}}
      assert sentence =~ "garden server"
    end
  end

  describe "a dropped link" do
    test "the call is held: audio dropped, controls kept, and resumed past what was applied",
         ctx do
      bridge = call_up!(ctx.relay, schedule: fn message, _ms -> send(self(), message) end)
      {:cont, bridge} = CallBridge.info(bridge, {:relay_call_link, :down, "gone"})
      assert_received {:call_bridge_window, _token}

      {:cont, bridge} = CallBridge.event(bridge, audio(@pcm))
      {:cont, bridge} = CallBridge.event(bridge, event("mute", %{"enabled" => true}))
      # A call to the relay is answered after every cast the bridge made.
      _ = :sys.get_state(ctx.relay)
      refute_received {:up, _type, _fields, _bytes}

      {:cont, bridge} = CallBridge.info(bridge, {:relay_call_link, :up, nil})
      assert_receive {:up, "call_open", %{"resume" => true}, <<>>}

      # The server applied the start and never answered the hello.
      attached = %{"resumed" => true, "control_seq" => 1, "muted" => false, "camera" => false}
      {:cont, bridge} = down(bridge, "call_attached", <<>>, attached)
      assert_receive {:up, "call_line", %{}, hello}
      assert %{"type" => "client_hello"} = Jason.decode!(hello)
      assert_receive {:up, "call_line", %{"control_seq" => 2}, mute}
      assert %{"type" => "mute"} = Jason.decode!(mute)
      _ = :sys.get_state(ctx.relay)
      refute_received {:up, "call_line", %{"control_seq" => 1}, _start}

      # The window it armed is no longer the call's.
      assert {:cont, _bridge} = CallBridge.info(bridge, {:call_bridge_window, make_ref()})
    end

    test "past the server's window the call ends with a sentence", ctx do
      bridge = call_up!(ctx.relay, schedule: fn message, _ms -> send(self(), message) end)
      {:cont, bridge} = CallBridge.info(bridge, {:relay_call_link, :down, "gone"})
      assert_received {:call_bridge_window, _token} = window

      assert {:stop, _bridge} = CallBridge.info(bridge, window)
      assert_received {:app_event, %{type: "error", reason: "call_ended", sentence: sentence}}
      assert sentence =~ "garden server"
      assert_receive {:closed, "call-1"}
    end

    test "a server that no longer knows this computer ends the call", ctx do
      bridge = call_up!(ctx.relay)
      said = "The server garden server does not know this computer."
      assert {:stop, _bridge} = CallBridge.info(bridge, {:relay_call_link, :revoked, said})
      assert_received {:app_event, %{type: "error", reason: "call_ended", sentence: ^said}}
    end
  end

  # M97 §9.2: before a move back to this computer the call ends cleanly: it
  # is hung up, so the server settles it, and the app hears why.
  test "a move back hangs the call up, then tells the app why", ctx do
    bridge = call_up!(ctx.relay)
    why = "This call ended: Fermix is moving back to this Mac. Call again once the move is done."
    {:cont, bridge} = CallBridge.info(bridge, {:call_bridge_end, why})
    assert_receive {:up, "call_line", %{"control_seq" => 2}, stop}
    assert Jason.decode!(stop) == %{"type" => "call_stop"}

    {:cont, bridge} = down(bridge, "call_line", ~s({"type":"state","state":"idle"}))
    assert_received {:app, ~s({"type":"state","state":"idle"})}
    assert {:stop, _bridge} = down(bridge, "call_close", <<>>, %{"reason" => "ended"})
    assert_received {:app_event, %{type: "error", reason: "call_ended", sentence: ^why}}
  end

  # -- helpers ----------------------------------------------------------------------

  defp start_relay!(answer) do
    start_supervised!({FakeRelay, {self(), answer}}, id: make_ref())
  end

  defp open!(relay, version, more \\ []) do
    test = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    CallBridge.open(
      [
        relay: relay,
        protocol_version: version,
        write: fn json ->
          send(test, {:app, json})
          :ok
        end,
        emit: fn event ->
          send(test, {:app_event, event})
          :ok
        end,
        mint: fn -> "call-#{Agent.get_and_update(counter, &{&1 + 1, &1 + 1})}" end
      ] ++ more
    )
  end

  defp call_up!(relay, more \\ []) do
    {:cont, bridge} = CallBridge.event(open!(relay, 3, more), event("call_start"))
    assert_receive {:opened, _call_id}
    assert_receive {:up, "call_open", %{"resume" => false}, <<>>}
    assert_receive {:up, "call_line", %{}, _hello}
    assert_receive {:up, "call_line", %{"control_seq" => 1}, _start}
    {:cont, bridge} = down(bridge, "call_attached", <<>>, attached(false))
    bridge
  end

  defp attached(resumed?),
    do: %{"resumed" => resumed?, "muted" => false, "camera" => false, "control_seq" => 0}

  defp down(bridge, type, tail, fields \\ %{}) do
    CallBridge.info(bridge, {:relay_call, type, Map.put(fields, "call_id", bridge.call.id), tail})
  end

  defp event(type, payload \\ %{}), do: %{type: type, payload: payload}
  defp audio(pcm), do: event("audio_chunk", %{"audio" => pcm})
end
