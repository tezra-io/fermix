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
             engine: "openai_realtime",
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

  describe "engine axis (M41)" do
    test "engine defaults to the Realtime engine so an existing config is untouched" do
      assert Config.normalize([]).engine == "openai_realtime"
      refute Config.live?(Config.normalize([]))
    end

    test "valid_engines names both engines, realtime first" do
      assert Config.valid_engines() == ["openai_realtime", "openai_live"]
    end

    test "rejects an unknown engine and names the accepted ones" do
      assert_raise ArgumentError,
                   ~s(realtime.engine must be one of openai_realtime, openai_live, got: "gpt_live"),
                   fn -> Config.normalize(engine: "gpt_live") end
    end

    test "valid_models/1 is engine-scoped and valid_models/0 stays the Realtime list" do
      assert Config.valid_models("openai_realtime") == Config.valid_models()
      assert Config.valid_models("openai_live") == ["gpt-live-1"]
    end

    # The model is the one operator-facing choice, so the combined list and the
    # derivation are two halves of it: every slug the list offers has to resolve
    # to an engine, and the order is the order of the dropdown.
    test "all_models/0 is both catalogs, Realtime first, and every slug derives an engine" do
      assert Config.all_models() ==
               Config.valid_models("openai_realtime") ++ Config.valid_models("openai_live")

      assert Config.all_models() == ~w(gpt-realtime-2.1-mini gpt-realtime-2.1 gpt-realtime-2
               gpt-live-1)

      for model <- Config.all_models() do
        assert {:ok, engine} = Config.engine_for_model(model)
        assert model in Config.valid_models(engine)
      end
    end

    test "engine_for_model/1 names each engine and answers :error for a slug no engine ships" do
      assert Config.engine_for_model("gpt-realtime-2") == {:ok, "openai_realtime"}
      assert Config.engine_for_model("gpt-realtime-2.1-mini") == {:ok, "openai_realtime"}
      assert Config.engine_for_model("gpt-live-1") == {:ok, "openai_live"}
      assert Config.engine_for_model("gpt-realtime-9") == :error
      assert Config.engine_for_model("") == :error
    end

    test "valid_voices/1 is engine-scoped and valid_voices/0 stays the Realtime list" do
      assert Config.valid_voices("openai_realtime") == Config.valid_voices()
      assert length(Config.valid_voices("openai_live")) == 22
      assert "beacon" in Config.valid_voices("openai_live")
      refute "beacon" in Config.valid_voices("openai_realtime")
    end

    test "default_model/1 is engine-scoped and keeps the Realtime struct default" do
      assert Config.default_model("openai_realtime") == "gpt-realtime-2"
      assert Config.default_model("openai_live") == "gpt-live-1"
      assert Config.normalize([]).model == Config.default_model("openai_realtime")
    end

    test "live?/1 answers for a normalized config" do
      assert Config.live?(Config.normalize(engine: "openai_live"))
      refute Config.live?(Config.normalize(engine: "openai_realtime"))
    end

    test "the live engine takes the live model by default" do
      config = Config.normalize(engine: "openai_live")

      assert config.model == "gpt-live-1"
      assert config.engine == "openai_live"
    end

    test "a Realtime model under the live engine is refused" do
      assert_raise ArgumentError,
                   ~s(realtime.model must be gpt-live-1 when engine = "openai_live", got: "gpt-realtime-2.1"),
                   fn -> Config.normalize(engine: "openai_live", model: "gpt-realtime-2.1") end
    end

    test "the live model under the Realtime engine names the setting to change" do
      assert_raise ArgumentError,
                   ~s(realtime.model gpt-live-1 requires engine = "openai_live"; ) <>
                     ~s(set [fermix_core.realtime] engine = "openai_live" or pick a Realtime model),
                   fn -> Config.normalize(model: "gpt-live-1") end
    end

    test "a Realtime-only setting present under the live engine is refused, not ignored" do
      for {key, value} <- [
            reasoning_effort: "low",
            transcription_model: "whisper-1",
            max_response_output_tokens: 2_048
          ] do
        assert_raise ArgumentError,
                     "realtime.#{key} is a Realtime-only setting; remove it from " <>
                       ~s([fermix_core.realtime] or set engine = "openai_realtime"),
                     fn -> Config.normalize([{:engine, "openai_live"}, {key, value}]) end
      end
    end

    test "the live engine normalizes the Realtime-only settings to nil" do
      config = Config.normalize(engine: "openai_live")

      assert config.reasoning_effort == nil
      assert config.transcription_model == nil
      assert config.max_response_output_tokens == nil
    end

    test "the Realtime engine keeps today's defaults for those settings" do
      config = Config.normalize(engine: "openai_realtime")

      assert config.reasoning_effort == "low"
      assert config.transcription_model == "whisper-1"
      assert config.max_response_output_tokens == 4_096
    end

    test "a live-only voice is accepted under live and refused under realtime" do
      assert Config.normalize(engine: "openai_live", voice: "beacon").voice == "beacon"

      assert_raise ArgumentError, ~r/realtime\.voice must be one of/, fn ->
        Config.normalize(voice: "beacon")
      end
    end

    test "every live voice normalizes under the live engine" do
      for voice <- Config.valid_voices("openai_live") do
        assert Config.normalize(engine: "openai_live", voice: voice).voice == voice
      end
    end

    test "to_keyword always emits the engine and drops reasoning_effort under live" do
      keyword = Config.to_keyword(Config.normalize(engine: "openai_live", voice: "cedar"))

      assert Keyword.get(keyword, :engine) == "openai_live"
      assert Keyword.get(keyword, :model) == "gpt-live-1"
      assert Keyword.get(keyword, :voice) == "cedar"
      refute Keyword.has_key?(keyword, :reasoning_effort)
    end

    test "normalize accepts its own to_keyword output for both engines (the save/load loop)" do
      for seed <- [
            [],
            [enabled: true, voice: "cedar", max_session_minutes: 20],
            [engine: "openai_live"],
            [engine: "openai_live", enabled: true, voice: "beacon", persist_transcripts: true]
          ] do
        normalized = Config.normalize(seed)

        assert normalized |> Config.to_keyword() |> Config.normalize() == normalized
      end
    end
  end
end
