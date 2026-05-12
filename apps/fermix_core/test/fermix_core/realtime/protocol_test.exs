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
