defmodule FermixCore.Realtime.ProtocolTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.Protocol

  test "decodes allowed client events" do
    config = Config.normalize([])

    assert {:ok, %{type: "call_start", payload: %{}}} =
             Protocol.decode_client_event(~s({"type":"call_start"}), config)

    assert {:ok, %{type: "interrupt", payload: %{}}} =
             Protocol.decode_client_event(~s({"type":"interrupt"}), config)

    assert {:ok, %{type: "interrupt", payload: %{"audio_end_ms" => 1_500}}} =
             Protocol.decode_client_event(
               ~s({"type":"interrupt","audio_end_ms":1500}),
               config
             )

    assert {:ok, %{type: "mute", payload: %{"enabled" => true}}} =
             Protocol.decode_client_event(~s({"type":"mute","enabled":true}), config)

    assert {:ok, %{type: "call_stop", payload: %{}}} =
             Protocol.decode_client_event(~s({"type":"call_stop"}), config)
  end

  test "decodes client_hello with a positive-integer protocol_version" do
    config = Config.normalize([])

    assert {:ok, %{type: "client_hello", payload: %{"protocol_version" => 1}}} =
             Protocol.decode_client_event(
               ~s({"type":"client_hello","protocol_version":1}),
               config
             )
  end

  test "rejects a client_hello without a valid protocol_version" do
    config = Config.normalize([])

    assert {:error, :missing_protocol_version} =
             Protocol.decode_client_event(~s({"type":"client_hello"}), config)

    assert {:error, :invalid_protocol_version} =
             Protocol.decode_client_event(
               ~s({"type":"client_hello","protocol_version":0}),
               config
             )

    assert {:error, :invalid_protocol_version} =
             Protocol.decode_client_event(
               ~s({"type":"client_hello","protocol_version":"1"}),
               config
             )
  end

  test "negotiate accepts the supported range and names the side that must update" do
    {min, max} = Protocol.supported_version_range()

    assert :ok = Protocol.negotiate(min)
    assert :ok = Protocol.negotiate(max)
    assert {:error, :client_too_old} = Protocol.negotiate(min - 1)
    assert {:error, :client_too_new} = Protocol.negotiate(max + 1)
  end

  test "exposes the version and event catalog as the source of truth" do
    assert Protocol.protocol_version() == 2
    assert Protocol.supported_version_range() == {1, 2}
    assert "client_hello" in Protocol.client_events()
    assert "server_hello" in Protocol.server_events()
  end

  test "v2 adds the Live client and server events without dropping a v1 event" do
    assert "task_cancel" in Protocol.client_events()

    for type <- ~w(call_ready caption task) do
      assert type in Protocol.server_events()
    end

    # Every v1 event still has to be speakable: a v1 companion runs the Realtime
    # engine against this same daemon.
    for type <- ~w(client_hello call_start audio_chunk interrupt mute call_stop) do
      assert type in Protocol.client_events()
    end

    for type <-
          ~w(server_hello state audio_delta transcript_delta assistant_text_delta tool_event
             usage error playback_stop) do
      assert type in Protocol.server_events()
    end
  end

  test "negotiate serves the whole v1/v2 window" do
    assert :ok = Protocol.negotiate(1)
    assert :ok = Protocol.negotiate(2)
    assert {:error, :client_too_new} = Protocol.negotiate(3)
  end

  test "decodes task_cancel with a non-empty delegation_id" do
    config = Config.normalize([])

    assert {:ok, %{type: "task_cancel", payload: %{"delegation_id" => "dg_1"}}} =
             Protocol.decode_client_event(
               ~s({"type":"task_cancel","delegation_id":"dg_1"}),
               config
             )
  end

  test "rejects a task_cancel without a usable delegation_id" do
    config = Config.normalize([])

    for frame <- [
          ~s({"type":"task_cancel"}),
          ~s({"type":"task_cancel","delegation_id":""}),
          ~s({"type":"task_cancel","delegation_id":7}),
          ~s({"type":"task_cancel","delegation_id":null})
        ] do
      assert {:error, :missing_delegation_id} = Protocol.decode_client_event(frame, config),
             "expected #{frame} to be refused"
    end
  end

  test "encodes the Live server frames" do
    assert {:ok, line} =
             Protocol.encode_server_event("call_ready", %{
               engine: "openai_live",
               call_id: "voice_live:1",
               provider_session_id: "sess_1",
               expires_at: 1_800,
               captions: true
             })

    assert %{"type" => "call_ready", "engine" => "openai_live", "captions" => true} =
             Jason.decode!(String.trim_trailing(line))

    assert {:ok, line} =
             Protocol.encode_server_event("caption", %{
               speaker: "user",
               delta: "hello ",
               start_ms: 0,
               end_ms: 400
             })

    assert %{"type" => "caption", "speaker" => "user", "delta" => "hello "} =
             Jason.decode!(String.trim_trailing(line))

    assert {:ok, line} =
             Protocol.encode_server_event("task", %{
               delegation_id: "dg_1",
               revision: 1,
               status: "running"
             })

    assert %{"type" => "task", "delegation_id" => "dg_1", "revision" => 1} =
             Jason.decode!(String.trim_trailing(line))
  end

  test "encodes the server_hello handshake reply" do
    assert {:ok, line} =
             Protocol.encode_server_event("server_hello", %{min_version: 1, max_version: 2})

    assert Jason.decode!(String.trim_trailing(line)) == %{
             "type" => "server_hello",
             "min_version" => 1,
             "max_version" => 2
           }
  end

  test "rejects removed half-duplex events" do
    config = Config.normalize([])

    assert {:error, {:unknown_event, "listen_start"}} =
             Protocol.decode_client_event(~s({"type":"listen_start"}), config)

    assert {:error, {:unknown_event, "listen_stop"}} =
             Protocol.decode_client_event(~s({"type":"listen_stop"}), config)

    assert {:error, {:unknown_event, "session_stop"}} =
             Protocol.decode_client_event(~s({"type":"session_stop"}), config)
  end

  test "rejects negative or non-integer audio_end_ms on interrupt" do
    config = Config.normalize([])

    assert {:error, :invalid_audio_end_ms} =
             Protocol.decode_client_event(~s({"type":"interrupt","audio_end_ms":-1}), config)

    assert {:error, :invalid_audio_end_ms} =
             Protocol.decode_client_event(~s({"type":"interrupt","audio_end_ms":"500"}), config)
  end

  test "decodes audio chunks from base64 and enforces configured decoded size" do
    config = Config.normalize(max_chunk_bytes: 4)
    encoded = Base.encode64("1234")

    assert {:ok, %{type: "audio_chunk", payload: %{"audio" => "1234"}}} =
             Protocol.decode_client_event(~s({"type":"audio_chunk","audio":"#{encoded}"}), config)

    too_large = Base.encode64("12345")

    assert {:error, {:chunk_too_large, 5, 4}} =
             Protocol.decode_client_event(
               ~s({"type":"audio_chunk","audio":"#{too_large}"}),
               config
             )
  end

  test "rejects malformed and unknown client events loudly" do
    config = Config.normalize([])

    assert {:error, :invalid_json} = Protocol.decode_client_event("{", config)

    assert {:error, {:unknown_event, "bogus"}} =
             Protocol.decode_client_event(~s({"type":"bogus"}), config)

    assert {:error, :missing_type} = Protocol.decode_client_event(~s({"audio":"x"}), config)
  end

  test "encodes daemon events as newline-delimited JSON" do
    assert {:ok, line} = Protocol.encode_server_event("state", %{state: "listening"})
    assert String.ends_with?(line, "\n")
    assert {:ok, decoded} = Jason.decode(String.trim_trailing(line))
    assert decoded == %{"type" => "state", "state" => "listening"}

    assert {:ok, line} = Protocol.encode_server_event("playback_stop", %{})
    assert Jason.decode!(String.trim_trailing(line)) == %{"type" => "playback_stop"}
  end
end
