defmodule FermixCore.Realtime.LiveFramesTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.LiveFrames
  alias FermixCore.Realtime.LiveLedger
  alias FermixCore.Realtime.Protocol

  @call_uuid "6f1c2a4e-9b3d-4c5e-8a7f-0123456789ab"

  test "every frame this module builds is a type the protocol publishes" do
    frames = [
      LiveFrames.state("listening"),
      LiveFrames.audio_delta("AAAA"),
      LiveFrames.playback_stop(),
      LiveFrames.caption("user", "hi", 0, 100),
      LiveFrames.call_ready("openai_live", "voice_live:1", @call_uuid, "chat", nil, nil),
      LiveFrames.task(@call_uuid, "dg_1", 1, "running", nil),
      LiveFrames.usage(@call_uuid, LiveLedger.usage_payload(LiveLedger.new(100, 0))),
      LiveFrames.error(:cost_limit)
    ]

    for %{type: type} <- frames do
      assert type in Protocol.server_events()
    end
  end

  describe "call_ready/6" do
    test "omits the provider session and expiry while they are unknown" do
      frame = LiveFrames.call_ready("openai_live", "voice_live:1", @call_uuid, "chat", nil, nil)

      assert frame == %{
               type: "call_ready",
               engine: "openai_live",
               call_id: "voice_live:1",
               call_uuid: @call_uuid,
               conversation: "chat",
               captions: true
             }
    end

    # M56 §6: whether the call's hand-offs join the chat or keep to the call.
    test "names the conversation the call's hand-offs run in" do
      for conversation <- ~w(chat private) do
        frame =
          LiveFrames.call_ready("openai_live", "voice_live:1", @call_uuid, conversation, nil, nil)

        assert frame.conversation == conversation
      end

      assert_raise FunctionClauseError, fn ->
        LiveFrames.call_ready("openai_live", "voice_live:1", @call_uuid, "shared", nil, nil)
      end
    end

    test "carries them once the provider reported them" do
      frame =
        LiveFrames.call_ready(
          "openai_live",
          "voice_live:1",
          @call_uuid,
          "chat",
          "sess_1",
          1_788_000_000
        )

      assert frame.provider_session_id == "sess_1"
      assert frame.expires_at == 1_788_000_000
    end
  end

  describe "task/5" do
    test "omits an absent summary and bounds a long one to the wire's limit" do
      assert LiveFrames.task(@call_uuid, "dg_1", 1, "running", nil) == %{
               type: "task",
               call_uuid: @call_uuid,
               delegation_id: "dg_1",
               revision: 1,
               status: "running"
             }

      long = LiveFrames.task(@call_uuid, "dg_1", 2, "completed", String.duplicate("a", 900))

      assert String.length(long.summary) == 240
      assert String.ends_with?(long.summary, "…")
    end

    test "refuses a status the protocol does not publish" do
      assert_raise FunctionClauseError, fn ->
        LiveFrames.task(@call_uuid, "dg_1", 1, "queued", nil)
      end
    end

    # M56 §6: the row a result was shown at, so the app can say it is in the
    # chat. Additive and optional: absent when nothing was shown.
    test "names the chat row a result was shown at" do
      frame = LiveFrames.task(@call_uuid, "dg_1", 1, "completed", "It is in the chat.", 42)

      assert frame.server_seq == 42

      refute Map.has_key?(
               LiveFrames.task(@call_uuid, "dg_1", 1, "completed", "Done.", nil),
               :server_seq
             )

      assert_raise FunctionClauseError, fn ->
        LiveFrames.task(@call_uuid, "dg_1", 1, "completed", nil, 0)
      end
    end
  end

  describe "state/1" do
    test "refuses a vocabulary word PROTOCOL.md does not document" do
      assert LiveFrames.state("speaking") == %{type: "state", state: "speaking"}
      assert_raise FunctionClauseError, fn -> LiveFrames.state("busy") end
    end
  end

  describe "usage/3" do
    test "passes the ledger payload through and can override the status" do
      payload = LiveLedger.usage_payload(LiveLedger.new(100, 0))

      assert LiveFrames.usage(@call_uuid, payload).status == "live"
      assert LiveFrames.usage(@call_uuid, payload, "limit_reached").status == "limit_reached"
      assert LiveFrames.usage(@call_uuid, payload).backend_cost == "unknown"
    end

    test "names the call the bill belongs to" do
      payload = LiveLedger.usage_payload(LiveLedger.new(100, 0))

      assert LiveFrames.usage(@call_uuid, payload).call_uuid == @call_uuid
    end
  end

  describe "error/2" do
    test "names the published kind for every terminal reason" do
      for {reason, kind} <- [
            {:voice_bridge_unavailable, "bridge_unavailable"},
            {:bridge_unavailable, "bridge_unavailable"},
            {:cost_limit, "cost_limit"},
            {:session_expired, "session_expired"},
            {:close_timeout, "close_timeout"},
            {:max_session_duration, "max_session_duration"},
            {:provider_disconnected, "provider_disconnected"},
            {:provider_refused, "provider_refused"}
          ] do
        assert LiveFrames.error(reason) == %{
                 type: "error",
                 reason: Atom.to_string(reason),
                 kind: kind
               }
      end
    end

    test "omits the kind for a reason with no documented one" do
      assert LiveFrames.error(:something_else) == %{
               type: "error",
               reason: "something_else"
             }
    end

    test "carries a bounded vendor detail when there is one" do
      frame = LiveFrames.error(:provider_refused, String.duplicate("b", 900))

      assert String.length(frame.detail) == 240
    end

    # A refused handshake hands the session an exception struct, and this frame
    # is the last thing the companion hears: raising while building it cost a
    # whole call and closed the connection with nothing on it.
    test "renders a refused handshake as the vendor's own status line" do
      frame = LiveFrames.error(%WebSockex.RequestError{code: 401, message: "Unauthorized"})

      assert frame == %{type: "error", reason: "401 Unauthorized"}
    end

    test "never raises on a struct, map or tuple reason" do
      reasons = [
        %WebSockex.RequestError{code: 401, message: "Unauthorized"},
        %WebSockex.ConnError{original: :econnrefused},
        %RuntimeError{message: "boom"},
        %{"message" => "decoded from the wire"},
        %{code: "insufficient_quota"},
        {:missing, :api_key},
        {:shutdown, {:bad_return, []}}
      ]

      for reason <- reasons do
        frame = LiveFrames.error(reason, "401 Unauthorized")

        assert frame.type == "error"
        assert is_binary(frame.reason) and frame.reason != ""
        assert frame.detail == "401 Unauthorized"
      end
    end
  end
end
