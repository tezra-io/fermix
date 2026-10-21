defmodule FermixCore.Realtime.ProtocolContractTest do
  @moduledoc """
  Guards the canonical wire-contract export under `priv/realtime/` against the
  source of truth (`FermixCore.Realtime.Protocol`). A downstream consumer
  (`fermix-macos`) vendors the schema and fixtures pinned by checksum, so if
  these drift from the module the pet ships against a contract the daemon no
  longer speaks. This test is the daemon half of the cross-repo compatibility
  check described in `PROTOCOL.md`.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.LiveFrames
  alias FermixCore.Realtime.Protocol

  @schema_path Application.app_dir(:fermix_core, "priv/realtime/protocol.schema.json")
  @client_fixtures Application.app_dir(:fermix_core, "priv/realtime/fixtures/client_events.jsonl")
  @server_fixtures Application.app_dir(:fermix_core, "priv/realtime/fixtures/server_events.jsonl")
  @uuid_v4 ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  # The reasons a Grok call closes the connection on its playback feedback, or
  # ends on a bound of its own.
  @playback_reasons ~w(unknown_playback playback_regressed playback_beyond_sent playback_stalled
                       playback_overflow call_ids_exhausted)

  setup_all do
    %{schema: @schema_path |> File.read!() |> Jason.decode!()}
  end

  test "the schema's event enums match the protocol module", %{schema: schema} do
    assert MapSet.new(schema["$defs"]["clientEvent"]["properties"]["type"]["enum"]) ==
             MapSet.new(Protocol.client_events())

    assert MapSet.new(schema["$defs"]["serverEvent"]["properties"]["type"]["enum"]) ==
             MapSet.new(Protocol.server_events())
  end

  test "the schema's advertised version matches the protocol module", %{schema: schema} do
    {min, max} = Protocol.supported_version_range()

    assert schema["x-protocol-version"] == Protocol.protocol_version()
    assert schema["x-supported-version-range"] == %{"min" => min, "max" => max}
  end

  test "every per-event schema def is wired into a discriminator (no dangling defs)" do
    # A per-event def that nothing $refs enforces nothing — the schema would then
    # validate malformed frames the daemon rejects. Assert the `$defs` are actually
    # reachable from the clientEvent/serverEvent discriminators.
    raw = File.read!(@schema_path)
    schema = Jason.decode!(raw)

    per_event_defs = Map.keys(schema["$defs"]) -- ["clientEvent", "serverEvent"]

    for name <- per_event_defs do
      assert raw =~ "#/$defs/#{name}", "schema def #{name} is defined but never referenced"
    end
  end

  test "the constraint-bearing defs require the fields the daemon enforces", %{schema: schema} do
    defs = schema["$defs"]

    assert "protocol_version" in defs["client_hello"]["required"]
    assert "audio" in defs["audio_chunk"]["required"]
    assert "min_version" in defs["server_hello"]["required"]
    assert "max_version" in defs["server_hello"]["required"]
    assert "reason" in defs["error"]["required"]
  end

  test "the v2 defs require the fields the daemon enforces", %{schema: schema} do
    defs = schema["$defs"]

    assert "delegation_id" in defs["task_cancel"]["required"]
    assert "engine" in defs["call_ready"]["required"]
    assert "call_id" in defs["call_ready"]["required"]
    assert "captions" in defs["call_ready"]["required"]

    for field <- ~w(speaker delta start_ms end_ms) do
      assert field in defs["caption"]["required"]
    end

    for field <- ~w(delegation_id revision status) do
      assert field in defs["task"]["required"]
    end
  end

  # Additive and optional: an older companion ignores a field it does not know.
  # A Realtime call's frames never carry it.
  test "call_ready, task and usage publish the call UUID as an optional field", %{
    schema: schema
  } do
    for name <- ~w(call_ready task usage) do
      definition = schema["$defs"][name]

      assert %{"type" => "string", "format" => "uuid"} = definition["properties"]["call_uuid"],
             "#{name} does not publish call_uuid"

      refute "call_uuid" in definition["required"], "#{name} requires call_uuid"
    end
  end

  # M56 §6: whether a Live call's hand-offs join the chat. Additive and
  # optional, like the UUID: an older companion ignores it.
  test "call_ready publishes the call's conversation as an optional field", %{schema: schema} do
    definition = schema["$defs"]["call_ready"]

    assert %{"enum" => ["chat", "private"]} = definition["properties"]["conversation"]
    refute "conversation" in definition["required"]

    golden =
      @server_fixtures
      |> fixture_lines()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["type"] == "call_ready"))

    assert golden["conversation"] == "chat"
  end

  # M56 §6: the chat row a task's result was shown at. Additive and optional:
  # an older companion ignores it, and nothing shown leaves it absent.
  test "task publishes the chat row its result was shown at as an optional field", %{
    schema: schema
  } do
    definition = schema["$defs"]["task"]

    assert %{"type" => "integer", "minimum" => 1} = definition["properties"]["server_seq"]
    refute "server_seq" in definition["required"]

    shown =
      @server_fixtures
      |> fixture_lines()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["type"] == "task" and Map.has_key?(&1, "server_seq")))

    assert %{"status" => "completed", "server_seq" => seq} = shown
    assert is_integer(seq) and seq > 0
  end

  # M56 §4.6, §6: a call in the chat's tasks outlive it, and the session says
  # so on the frame that detaches one. Both additive and optional: an older
  # companion ignores them.
  test "call_ready says whether tasks outlive the call, and task that one was detached", %{
    schema: schema
  } do
    ready = schema["$defs"]["call_ready"]
    task = schema["$defs"]["task"]

    assert %{"type" => "boolean"} = ready["properties"]["tasks_outlive_call"]
    refute "tasks_outlive_call" in ready["required"]
    assert %{"type" => "boolean"} = task["properties"]["detached"]
    refute "detached" in task["required"]

    golden =
      @server_fixtures
      |> fixture_lines()
      |> Enum.map(&Jason.decode!/1)

    assert %{"tasks_outlive_call" => true} = Enum.find(golden, &(&1["type"] == "call_ready"))

    assert %{"status" => "running", "detached" => true} =
             Enum.find(golden, &(&1["type"] == "task" and Map.has_key?(&1, "detached")))
  end

  test "the one-call refusal is a published error reason with a golden row", %{schema: schema} do
    reason = Protocol.call_in_progress()

    assert reason == "call_in_progress"
    assert schema["$defs"]["error"]["properties"]["reason"]["description"] =~ reason

    golden =
      @server_fixtures
      |> fixture_lines()
      |> Enum.map(&Jason.decode!/1)

    assert %{"type" => "error", "reason" => reason} in golden
  end

  test "the golden Live frames carry the call UUID" do
    server_frames =
      @server_fixtures
      |> fixture_lines()
      |> Enum.map(&Jason.decode!/1)

    live_frames =
      Enum.filter(server_frames, fn frame ->
        frame["type"] in ~w(call_ready task) or
          (frame["type"] == "usage" and frame["status"] == "live")
      end)

    assert length(live_frames) == 7

    for frame <- live_frames do
      assert frame["call_uuid"] =~ @uuid_v4, "golden #{frame["type"]} has no call_uuid"
    end
  end

  test "the error def publishes the typed failure vocabulary", %{schema: schema} do
    error = schema["$defs"]["error"]["properties"]

    assert MapSet.new(error["kind"]["enum"]) ==
             MapSet.new(~w(update_required provider_refused cost_limit session_expired
                           close_timeout bridge_unavailable max_session_duration
                           provider_disconnected))

    assert error["detail"]["type"] == "string"
    assert error["required_for"]["enum"] == ["openai_live", "xai_realtime"]
  end

  test "call_ready publishes every engine the daemon runs", %{schema: schema} do
    assert MapSet.new(schema["$defs"]["call_ready"]["properties"]["engine"]["enum"]) ==
             MapSet.new(Config.valid_engines())
  end

  # v3, the Grok engine: the companion reports playback against the id the
  # daemon sent, so both ends of the id carry the same bound.
  test "the v3 defs require the fields the daemon enforces", %{schema: schema} do
    defs = schema["$defs"]
    config = Config.normalize([])

    for field <- ~w(playback_id played_ms drained) do
      assert field in defs["playback_progress"]["required"]
    end

    assert %{"type" => "integer", "minimum" => 0} =
             defs["playback_progress"]["properties"]["played_ms"]

    assert %{"type" => "boolean"} = defs["playback_progress"]["properties"]["drained"]

    refute "playback_id" in defs["audio_delta"]["required"]
    sent = defs["audio_delta"]["properties"]["playback_id"]
    echoed = defs["playback_progress"]["properties"]["playback_id"]
    assert %{"type" => "string", "minLength" => 1, "maxLength" => max} = sent
    assert Map.delete(echoed, "description") == Map.delete(sent, "description")

    longest = String.duplicate("p", max)
    assert %{playback_id: ^longest} = LiveFrames.audio_delta("AAAA", longest)
    assert_raise FunctionClauseError, fn -> LiveFrames.audio_delta("AAAA", longest <> "p") end

    frame = &~s({"type":"playback_progress","playback_id":"#{&1}","played_ms":0,"drained":true})
    assert {:ok, _event} = Protocol.decode_client_event(frame.(longest), config)

    assert {:error, :missing_playback_id} =
             Protocol.decode_client_event(frame.(longest <> "p"), config)
  end

  test "the playback refusals are published error reasons with golden rows", %{schema: schema} do
    description = schema["$defs"]["error"]["properties"]["reason"]["description"]

    golden =
      @server_fixtures
      |> fixture_lines()
      |> Enum.map(&Jason.decode!/1)

    for reason <- @playback_reasons do
      assert description =~ reason, "the error def does not publish #{reason}"
      assert %{"type" => "error", "reason" => reason} in golden, "no golden #{reason} row"
    end
  end

  test "the golden Grok audio frame is the one the daemon builds" do
    golden =
      @server_fixtures
      |> fixture_lines()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["type"] == "audio_delta" and Map.has_key?(&1, "playback_id")))

    built =
      LiveFrames.audio_delta(golden["audio"], golden["playback_id"])
      |> Jason.encode!()
      |> Jason.decode!()

    assert built == golden
  end

  test "the golden fixtures carry every handshake version and every v2 and v3 frame" do
    client_types =
      @client_fixtures
      |> fixture_lines()
      |> Enum.map(&Jason.decode!/1)

    {min, max} = Protocol.supported_version_range()

    for version <- min..max do
      assert Enum.any?(
               client_types,
               &(&1["type"] == "client_hello" and &1["protocol_version"] == version)
             ),
             "no golden client_hello at version #{version}"
    end

    assert Enum.any?(client_types, &(&1["type"] == "task_cancel"))
    assert Enum.any?(client_types, &(&1["type"] == "playback_progress" and &1["drained"]))
    assert Enum.any?(client_types, &(&1["type"] == "playback_progress" and not &1["drained"]))

    server_frames =
      @server_fixtures
      |> fixture_lines()
      |> Enum.map(&Jason.decode!/1)

    for type <- ~w(call_ready caption task) do
      assert Enum.any?(server_frames, &(&1["type"] == type)), "no golden #{type} frame"
    end

    assert Enum.any?(server_frames, &(&1["type"] == "usage" and &1["status"] == "live")),
           "no golden Live usage frame"

    for engine <- ~w(openai_live xai_realtime) do
      assert Enum.any?(
               server_frames,
               &(&1["kind"] == "update_required" and &1["required_for"] == engine)
             ),
             "no golden update_required refusal for #{engine}"

      assert Enum.any?(server_frames, &(&1["type"] == "call_ready" and &1["engine"] == engine)),
             "no golden call_ready for #{engine}"
    end

    assert Enum.any?(
             server_frames,
             &(&1["type"] == "usage" and is_integer(&1["voice_text_items"]))
           ),
           "no golden Grok usage frame"
  end

  test "the golden server_hello advertises the module's live window", %{schema: _schema} do
    {min, max} = Protocol.supported_version_range()

    hello =
      @server_fixtures
      |> fixture_lines()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["type"] == "server_hello"))

    assert hello == %{"type" => "server_hello", "min_version" => min, "max_version" => max}
  end

  test "every golden client frame decodes against the live protocol" do
    config = Config.normalize([])

    for frame <- fixture_lines(@client_fixtures) do
      decoded = Jason.decode!(frame)
      assert decoded["type"] in Protocol.client_events(), "unknown client type in #{frame}"

      assert {:ok, %{type: _type}} = Protocol.decode_client_event(frame, config),
             "golden client frame did not decode: #{frame}"
    end
  end

  test "every golden server frame is reproduced exactly by the encoder" do
    for frame <- fixture_lines(@server_fixtures) do
      decoded = Jason.decode!(frame)
      type = decoded["type"]
      assert type in Protocol.server_events(), "unknown server type in #{frame}"

      assert {:ok, line} = Protocol.encode_server_event(type, Map.delete(decoded, "type"))

      assert Jason.decode!(String.trim_trailing(line)) == decoded,
             "encoder did not round-trip golden server frame: #{frame}"
    end
  end

  defp fixture_lines(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
  end
end
