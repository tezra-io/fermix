defmodule FermixCore.Realtime.ConfigTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.Config

  test "defaults to disabled OpenAI realtime config" do
    config = Config.normalize([])

    assert config.enabled? == false
    assert config.provider == "openai"
    assert config.model == "gpt-realtime-2"
    assert config.reasoning_effort == "low"
    assert config.voice == "marin"
    refute Map.has_key?(config, :activation)
    refute Map.has_key?(config, :turn_detection)
    assert config.input_audio_format == "pcm16"
    assert config.output_audio_format == "pcm16"
    assert config.max_chunk_bytes == 16_384
    assert config.max_session_minutes == 15
    assert config.max_estimated_cost_cents_per_session == 100
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
        persist_transcripts: true
      )

    assert Config.to_keyword(config) == [
             enabled: true,
             provider: "openai",
             model: "gpt-realtime-2",
             reasoning_effort: "low",
             voice: "cedar",
             max_session_minutes: 20,
             max_estimated_cost_cents_per_session: 35,
             screen_share: true,
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

  test "valid_models is the common source, mini first for the dropdown" do
    assert Config.valid_models() == [
             "gpt-realtime-2.1-mini",
             "gpt-realtime-2.1",
             "gpt-realtime-2"
           ]
  end

  test "accepts every model in the common valid list" do
    for model <- Config.valid_models() do
      assert Config.normalize(model: model).model == model
    end
  end

  test "valid_voices lists the full official set, curated voices first for the dropdown" do
    assert Config.valid_voices() == [
             "marin",
             "sage",
             "verse",
             "cedar",
             "alloy",
             "ash",
             "ballad",
             "coral",
             "echo",
             "shimmer"
           ]
  end

  test "accepts an official voice carried over from a pre-dropdown config (upgrade safety)" do
    # Earlier Fermix accepted any voice; validating to only the curated four
    # crashed normalization — which runs on setup render AND daemon boot/readiness
    # — for a config upgraded with e.g. voice: "alloy" or "echo". Every official
    # OpenAI Realtime voice must normalize without raising.
    for voice <- ~w(alloy ash ballad coral echo shimmer) do
      assert Config.normalize(voice: voice).voice == voice
    end
  end

  test "valid_reasoning_efforts is the common source, ordered low to high" do
    assert Config.valid_reasoning_efforts() == ["minimal", "low", "medium", "high", "xhigh"]
  end

  test "accepts every voice and reasoning effort in the common lists" do
    for voice <- Config.valid_voices() do
      assert Config.normalize(voice: voice).voice == voice
    end

    for effort <- Config.valid_reasoning_efforts() do
      assert Config.normalize(reasoning_effort: effort).reasoning_effort == effort
    end
  end

  test "rejects an unsupported voice" do
    assert_raise ArgumentError, ~r/voice/, fn ->
      Config.normalize(voice: "robotic")
    end
  end

  test "rejects an unsupported reasoning effort" do
    # `max` is valid in the main-agent vocabulary but not the Realtime API's.
    assert_raise ArgumentError, ~r/reasoning_effort/, fn ->
      Config.normalize(reasoning_effort: "max")
    end
  end

  test "rejects removed realtime mode settings" do
    for key <- [
          :activation,
          :turn_detection,
          :max_buffer_chunks,
          :idle_timeout_ms,
          :max_input_audio_seconds_per_session,
          :tool_policy,
          :allow_network_tools
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
