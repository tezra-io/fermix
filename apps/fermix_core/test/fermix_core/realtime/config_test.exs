defmodule FermixCore.Realtime.ConfigTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.Config

  test "defaults to disabled OpenAI realtime config" do
    config = Config.normalize([])

    assert config.enabled? == false
    assert config.provider == "openai"
    assert config.model == "gpt-realtime-2"
    assert config.voice == "marin"
    refute Map.has_key?(config, :activation)
    refute Map.has_key?(config, :turn_detection)
    assert config.input_audio_format == "pcm16"
    assert config.output_audio_format == "pcm16"
    assert config.max_chunk_bytes == 16_384
    assert config.max_session_minutes == 15
    assert config.max_estimated_cost_cents_per_session == 100
    assert config.allow_network_tools? == false
    assert config.persist_transcripts? == false
    assert config.persist_audio? == false
    assert config.transcription_model == "whisper-1"
    assert config.max_response_output_tokens == 4_096
  end

  test "persists only the operator-facing realtime config surface" do
    config =
      Config.normalize(
        enabled: true,
        voice: "cedar",
        max_session_minutes: 20,
        max_estimated_cost_cents_per_session: 35,
        allow_network_tools: true,
        persist_transcripts: true
      )

    assert Config.to_keyword(config) == [
             enabled: true,
             provider: "openai",
             model: "gpt-realtime-2",
             voice: "cedar",
             max_session_minutes: 20,
             max_estimated_cost_cents_per_session: 35,
             allow_network_tools: true,
             persist_transcripts: true
           ]
  end

  test "accepts custom transcription_model and max_response_output_tokens" do
    config =
      Config.normalize(
        transcription_model: "gpt-4o-transcribe",
        max_response_output_tokens: 2_048
      )

    assert config.transcription_model == "gpt-4o-transcribe"
    assert config.max_response_output_tokens == 2_048
  end

  test "rejects raw audio persistence in V1" do
    assert_raise ArgumentError, ~r/persist_audio/, fn ->
      Config.normalize(persist_audio: true)
    end
  end

  test "rejects unsupported provider" do
    assert_raise ArgumentError, ~r/provider/, fn ->
      Config.normalize(provider: "anthropic")
    end
  end

  test "rejects unsupported realtime model" do
    assert_raise ArgumentError, ~r/model/, fn ->
      Config.normalize(model: "gpt-realtime")
    end
  end

  test "rejects removed realtime mode settings" do
    for key <- [
          :activation,
          :turn_detection,
          :max_buffer_chunks,
          :idle_timeout_ms,
          :max_input_audio_seconds_per_session,
          :tool_policy
        ] do
      assert_raise ArgumentError, ~r/#{key}.*removed/, fn ->
        Config.normalize([{key, "removed"}])
      end
    end
  end

  test "socket_path is rooted under the realtime workspace directory" do
    assert Config.socket_path("/tmp/fermix-home") == "/tmp/fermix-home/realtime.sock"
  end
end
