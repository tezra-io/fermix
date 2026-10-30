defmodule FermixCore.Companion.ProtocolContractTest do
  @moduledoc """
  Guards the canonical wire-contract export under `priv/companion/` against the
  source of truth (`FermixCore.Companion.Protocol`). A downstream consumer
  (`fermix-macos`) vendors the schema and fixtures pinned by checksum, so if
  these drift from the module the app ships against a contract the daemon no
  longer speaks. It also holds the one chat vocabulary to itself: every chat
  event the mobile export shares has the same required fields in both.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Companion.Protocol
  alias FermixCore.Cues.ProposalView
  alias FermixCore.ReplyBlocks

  @priv_dir Application.app_dir(:fermix_core, "priv/companion")
  @schema_path Path.join(@priv_dir, "protocol.schema.json")
  @protocol_path Path.join(@priv_dir, "PROTOCOL.md")
  @client_fixtures Path.join(@priv_dir, "fixtures/client_events.jsonl")
  @server_fixtures Path.join(@priv_dir, "fixtures/server_events.jsonl")
  @mobile_schema_path Application.app_dir(:fermix_core, "priv/mobile/protocol.schema.json")
  @inert_keywords ~w($schema $id $defs title description)
  # The fields the phone's wire requires of a shared event beyond this wire's.
  # None since version 3, when this wire's `row` came to require `media_refs`.
  @phone_only_required %{}
  # The events version 3 brought (M66): the media grant and the changed row.
  @version_3_client_events ~w(media_fetch media_release)
  @version_3_server_events ~w(row_updated media_path media_missing)
  # The events version 4 brought (M60 app surface §3.7): a mandate's proposals.
  @version_4_client_events ~w(proposal_answer)
  @version_4_server_events ~w(proposal proposal_resolved)
  # The follow-up's fields of a card version 5 brought (M60_WATCHER_CODING_RUNS.md §6.2).
  @follow_up_fields ~w(asks name instructions tools reports_to daily_cap set_off_by)

  setup_all do
    %{
      schema: @schema_path |> File.read!() |> Jason.decode!(),
      protocol: File.read!(@protocol_path)
    }
  end

  test "the schema's event enums match the protocol module", %{schema: schema} do
    assert schema["$defs"]["clientEvent"]["properties"]["type"]["enum"] ==
             Protocol.client_events()

    assert schema["$defs"]["serverEvent"]["properties"]["type"]["enum"] ==
             Protocol.server_events()
  end

  test "the schema's version window and line cap match the protocol module", %{schema: schema} do
    {min, max} = Protocol.supported_version_range()

    assert schema["x-protocol-version"] == Protocol.protocol_version()
    assert schema["x-supported-version-range"] == %{"min" => min, "max" => max}
    assert schema["x-max-line-bytes"] == Protocol.max_line_bytes()
  end

  # A client below an event's version is never sent it (M56 §6), so the
  # export names that version where it is not 1, as the module does.
  test "each server event def names the version that brought it", %{schema: schema} do
    for type <- Protocol.server_events() do
      assert Map.get(schema["$defs"][type], "x-since-version", 1) ==
               Protocol.server_event_version(type),
             "#{type} names a different version than the protocol module"
    end
  end

  # A connection that sends an event newer than its hello declared is
  # refused, so the export names that version as the module does.
  test "each client event def names the version that brought it", %{schema: schema} do
    for type <- Protocol.client_events() do
      assert Map.get(schema["$defs"][type], "x-since-version", 1) ==
               Protocol.client_event_version(type),
             "#{type} names a different version than the protocol module"
    end
  end

  # M66: the grant and the changed row are version 3's, on this wire alone:
  # the phone's own `media_fetch` streams bytes rather than granting a file.
  test "the media grant and row_updated are version 3 events this wire does not share", %{
    schema: schema,
    protocol: protocol
  } do
    for type <- @version_3_client_events do
      assert Protocol.client_event_version(type) == 3, "#{type} is not a version 3 event"
      assert schema["$defs"][type]["x-since-version"] == 3
      refute type in Protocol.shared_client_events()
    end

    for type <- @version_3_server_events do
      assert Protocol.server_event_version(type) == 3, "#{type} is not a version 3 event"
      assert schema["$defs"][type]["x-since-version"] == 3
      refute type in Protocol.shared_server_events()
    end

    assert protocol =~ "### Version 3: phone-side media and rows that change"
    assert protocol =~ "streams the bytes"
  end

  # M60 app surface §3.7: the proposal events are version 4's, on this wire
  # alone until the phone's wire carries them, and only for the owner.
  test "the proposal events are version 4 events this wire does not share", %{
    schema: schema,
    protocol: protocol
  } do
    for type <- @version_4_client_events do
      assert Protocol.client_event_version(type) == 4, "#{type} is not a version 4 event"
      assert schema["$defs"][type]["x-since-version"] == 4
      refute type in Protocol.shared_client_events()
    end

    for type <- @version_4_server_events do
      assert Protocol.server_event_version(type) == 4, "#{type} is not a version 4 event"
      assert schema["$defs"][type]["x-since-version"] == 4
      refute type in Protocol.shared_server_events()
    end

    assert Protocol.owner_server_events() == @version_4_server_events
    assert protocol =~ "### Version 4: proposals on the owner's devices"
    assert protocol =~ "## Proposals"

    assert String.replace(protocol, ~r/\s+/, " ") =~
             "Only the owner can answer a proposal, from the Fermix app or a paired phone."
  end

  # M60_WATCHER_CODING_RUNS.md §6.2: a watcher's follow-up card needs version
  # 5, since a version 4 client requires a mandate's call on every card; it is
  # answered and ended as a proposal is.
  test "a follow-up's card is version 5's, and only such a card needs it", %{
    schema: schema,
    protocol: protocol
  } do
    assert Protocol.protocol_version() == 5
    assert Protocol.supported_version_range() == {4, 5}
    assert schema["$defs"]["followUpCard"]["x-since-version"] == 5

    assert schema["$defs"]["followUpCard"]["properties"] |> Map.keys() |> Enum.sort() ==
             Enum.sort(@follow_up_fields)

    goldens = @server_fixtures |> jsonl() |> Enum.filter(&(&1["type"] == "proposal"))
    {follow_ups, mandates} = Enum.split_with(goldens, &Map.has_key?(&1["proposal"], "follow_up"))

    assert Enum.map(follow_ups, & &1["proposal"]["follow_up"]["asks"]) == ["run", "automatic"]
    assert Enum.all?(follow_ups, &(Protocol.server_payload_version("proposal", &1) == 5))
    assert Enum.all?(mandates, &(Protocol.server_payload_version("proposal", &1) == 4))
    assert protocol =~ "### Version 5: a watcher's follow-ups on the owner's devices"
    assert protocol =~ "Every version 4 event, field and rule holds unchanged on version 5."
  end

  # The schema names every field of the card the engine builds, and bounds the
  # outside text as the codec does; the golden cards are the engine's shape.
  test "the proposal card's schema is the card Cues.ProposalView builds", %{schema: schema} do
    card_def = schema["$defs"]["proposalCard"]

    built =
      ProposalView.compact_card(%{
        id: "cpr_1",
        state: "confirmed",
        mandate: "release-issues",
        tool: "github_create_issue",
        job_id: "release_issues",
        job_name: "release issues",
        watcher: "release-watch",
        source_ref: "eng-blogs",
        created_at: ~U[2026-10-10 12:00:00Z],
        expires_at: ~U[2026-10-10 12:30:00Z],
        decided_at: ~U[2026-10-10 12:01:00Z],
        decided_from: "companion",
        result_status: "ok",
        args_json: ~s({"title":"Phoenix 2.0"}),
        received_at: ~U[2026-10-10 11:59:00Z],
        occurred_at: ~U[2026-10-10 11:58:30Z],
        snapshot: ~s({"type":"release","subject":"phoenix","text":"Phoenix 2.0 is out."}),
        decision_reason: "a Phoenix release"
      })

    assert built |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort() ==
             card_def["properties"] |> Map.keys() |> Enum.sort()

    assert built.outside |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort() ==
             card_def["properties"]["outside"]["properties"] |> Map.keys() |> Enum.sort()

    assert [%{name: "title", value: "Phoenix 2.0"}] = built.outside.args

    assert built.task |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort() ==
             card_def["properties"]["task"]["properties"] |> Map.keys() |> Enum.sort()

    assert built.outside.cue |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort() ==
             schema["$defs"]["proposalCue"]["properties"] |> Map.keys() |> Enum.sort()

    outside = card_def["properties"]["outside"]["properties"]
    assert outside["args_text"]["maxLength"] == Protocol.max_proposal_args_chars()
    assert Protocol.max_proposal_args_chars() == ProposalView.max_args_chars()

    assert schema["$defs"]["proposal_resolved"]["properties"]["result_text"]["maxLength"] ==
             Protocol.max_proposal_result_chars()

    goldens = @server_fixtures |> jsonl() |> Enum.filter(&(&1["type"] == "proposal"))
    assert Enum.any?(goldens, &Map.has_key?(&1["proposal"]["outside"], "cue"))
    refute Enum.all?(goldens, &Map.has_key?(&1["proposal"]["outside"], "cue"))

    for %{"proposal" => golden} <- goldens do
      assert Map.keys(golden) -- Map.keys(card_def["properties"]) == []
      assert card_def["required"] -- Map.keys(golden) == []
    end
  end

  test "the schema publishes the managed media files' budget and grace", %{
    schema: schema,
    protocol: protocol
  } do
    assert schema["x-media-budget-bytes"] == Protocol.media_budget_bytes()
    assert schema["x-media-release-grace-s"] == Protocol.media_release_grace_s()

    [_before, files] = String.split(protocol, "## Managed media files", parts: 2)
    assert files =~ "#{div(Protocol.media_budget_bytes(), 1_024 * 1_024)} MiB"
    assert files =~ "#{Protocol.media_release_grace_s()} s"
  end

  test "every per-event def is reachable from a discriminator" do
    raw = File.read!(@schema_path)
    schema = Jason.decode!(raw)

    for name <- Map.keys(schema["$defs"]) -- ["clientEvent", "serverEvent"] do
      assert raw =~ "#/$defs/#{name}", "schema def #{name} is defined but never referenced"
    end
  end

  test "the limits the daemon enforces are the ones the schema publishes", %{schema: schema} do
    defs = schema["$defs"]

    assert defs["history_pull"]["properties"]["limit"]["maximum"] == Protocol.max_history_limit()
    assert defs["history_search"]["properties"]["limit"]["maximum"] == Protocol.max_search_limit()

    assert defs["history_search"]["properties"]["query"]["maxLength"] ==
             Protocol.max_query_length()

    assert defs["msg"]["properties"]["attach_ids"]["maxItems"] == 0
  end

  test "each event def requires what the codec requires", %{schema: schema} do
    defs = schema["$defs"]

    for {type, payload} <- minimal_client_payloads(), field <- Map.keys(payload) do
      assert field in defs[type]["required"], "schema #{type} does not require #{field}"

      assert {:error, _reason} =
               Protocol.validate_client_payload(type, Map.delete(payload, field))
    end

    for {type, payload} <- fixture_payloads(@server_fixtures), type != "server_hello" do
      for field <- defs[type]["required"] -- ["type"] do
        assert {:error, {:missing_field, ^field}} =
                 Protocol.validate_server_payload(type, Map.delete(payload, field)),
               "codec accepts #{type} without #{field}"
      end
    end
  end

  test "the shared chat events have one shape on both wires", %{schema: schema} do
    mobile = @mobile_schema_path |> File.read!() |> Jason.decode!()

    for type <- Protocol.shared_client_events() ++ Protocol.shared_server_events() do
      companion_required = schema["$defs"][type]["required"] -- ["type"]
      mobile_required = mobile["$defs"][type]["required"] -- ["v", "t", "seq"]

      assert Enum.sort(companion_required ++ Map.get(@phone_only_required, type, [])) ==
               Enum.sort(mobile_required),
             "#{type} requires different fields on the two wires"
    end

    for type <- Protocol.shared_server_events() do
      companion = Map.delete(schema["$defs"][type]["properties"], "type")
      phone = Map.take(mobile["$defs"][type]["properties"], Map.keys(companion))

      assert phone == companion, "#{type} bounds a shared field differently on the two wires"
    end
  end

  test "a timeline row has one exported shape on both wires", %{schema: schema} do
    mobile = @mobile_schema_path |> File.read!() |> Jason.decode!()

    for def <- ~w(mediaRef linkPreviewCard replyBlock placesBlock place) do
      assert schema["$defs"][def] == mobile["$defs"][def], "#{def} differs between the wires"
    end

    # Only the phone's wire cuts a message past its 1 MiB event cap.
    phone_message =
      update_in(mobile["$defs"]["historyMessage"], ["properties"], &Map.delete(&1, "truncated"))

    assert schema["$defs"]["historyMessage"] == phone_message
  end

  # M56 §6: additive and optional on version 1, as a history message carries
  # them; a Live call's row is drawn from them.
  test "the Mac's row publishes kind and metadata, and a golden row carries a call", %{
    schema: schema,
    protocol: protocol
  } do
    row = schema["$defs"]["row"]

    for field <- ~w(kind metadata) do
      assert row["properties"][field] == schema["$defs"]["historyMessage"]["properties"][field]
      refute field in row["required"]
    end

    golden = @server_fixtures |> jsonl() |> Enum.find(&get_in(&1, ["metadata", "call"]))

    assert %{"type" => "row", "kind" => "text", "metadata" => %{"call" => call}} = golden
    assert :ok = Protocol.validate_call_metadata(call)
    assert call["event"] == "shared"

    # The same row as history pages it, the shape every client reads it in.
    paged =
      @server_fixtures
      |> jsonl()
      |> Enum.filter(&(&1["type"] == "history_page"))
      |> Enum.flat_map(& &1["messages"])
      |> Enum.find(&get_in(&1, ["metadata", "call"]))

    assert %{"role" => "assistant", "kind" => "text", "media_refs" => []} = paged
    assert paged["metadata"]["call"] == call
    assert paged["content"] == golden["text"]

    [_before, calls] = String.split(protocol, "### A Live call's rows", parts: 2)

    for key <- ~w(uuid event task_id revision state duration_s voice_cost_cents accounting) do
      assert calls =~ "| `#{key}` |", "PROTOCOL.md has no row for call.#{key}"
    end

    refute protocol =~ "This wire's `row` is unchanged"
  end

  # M66: a row carries the history message's media refs, always, and its link
  # previews when it has one, on every version, so a new row needs no read.
  test "every golden row carries its media refs, one a voice note, one a picture and a preview",
       %{schema: schema} do
    rows = @server_fixtures |> jsonl() |> Enum.filter(&(&1["type"] == "row"))

    assert Enum.all?(rows, &is_list(&1["media_refs"]))

    assert Enum.any?(
             rows,
             &match?([%{"kind" => "audio", "mime" => "audio/ogg"}], &1["media_refs"])
           )

    assert Enum.any?(rows, fn row ->
             row["media_refs"] != [] and match?([%{"image_ref" => _ref}], row["link_previews"])
           end)

    row = schema["$defs"]["row"]
    message = schema["$defs"]["historyMessage"]["properties"]

    for field <- ~w(media_refs link_previews) do
      assert row["properties"][field] == message[field], "row #{field} is not the message's"
    end

    assert "media_refs" in row["required"]
    refute "link_previews" in row["required"]
  end

  # M72 §8.3: a reply's blocks have one shape wherever the reply is carried, the
  # caps are the ones the builder keeps, and a golden of each is exactly what
  # the builder makes of its places for its text.
  test "a reply's blocks have one shape on text_done, row and history, with goldens", %{
    schema: schema,
    protocol: protocol
  } do
    defs = schema["$defs"]
    blocks = defs["historyMessage"]["properties"]["blocks"]

    for type <- ~w(text_done row) do
      assert defs[type]["properties"]["blocks"] == blocks, "#{type} blocks differ from history"
      refute "blocks" in defs[type]["required"]
    end

    assert blocks["maxItems"] == length(ReplyBlocks.types())
    assert defs["replyBlock"]["properties"]["type"]["enum"] == ReplyBlocks.types()
    assert defs["placesBlock"]["properties"]["places"]["maxItems"] == ReplyBlocks.max_places()
    assert defs["place"]["properties"]["categories"]["maxItems"] == ReplyBlocks.max_categories()

    server = jsonl(@server_fixtures)
    done = Enum.find(server, &(&1["type"] == "text_done" and Map.has_key?(&1, "blocks")))

    paged =
      server
      |> Enum.filter(&(&1["type"] == "history_page"))
      |> Enum.flat_map(& &1["messages"])
      |> Enum.find(&Map.has_key?(&1, "blocks"))

    assert %{"blocks" => [%{"type" => "places", "places" => [_ | _] = places}]} = done
    assert paged["blocks"] == done["blocks"]
    assert paged["content"] == done["text"]
    assert ReplyBlocks.build(done["text"], Enum.map(places, &record/1)) == done["blocks"]

    [_before, section] = String.split(protocol, "## Blocks under a reply", parts: 2)
    assert section =~ "skips a block `type` it does not know"
    assert section =~ "no version bump"
  end

  # M72 §14.1: an Apple Maps place adds its identifier, optional and additive,
  # and its golden is exactly what the builder makes of the search's records.
  test "an Apple Maps place's golden carries its identifier and is the builder's own", %{
    schema: schema,
    protocol: protocol
  } do
    place = schema["$defs"]["place"]

    assert place["properties"]["apple_place_id"] == %{"type" => "string", "minLength" => 1}
    refute "apple_place_id" in place["required"]

    done =
      @server_fixtures
      |> jsonl()
      |> Enum.find(
        &get_in(&1, ["blocks", Access.at(0), "places", Access.at(0), "apple_place_id"])
      )

    assert %{"type" => "text_done", "blocks" => [%{"places" => [_ | _] = places}]} = done
    assert ReplyBlocks.build(done["text"], Enum.map(places, &record/1)) == done["blocks"]
    assert :ok = Protocol.validate_server_payload("text_done", Map.delete(done, "type"))

    for golden <- places do
      assert golden["source_url"] ==
               "https://maps.apple.com/place?place-id=" <> golden["apple_place_id"]
    end

    [_before, section] = String.split(protocol, "## Blocks under a reply", parts: 2)
    assert section =~ "`apple_place_id`"
  end

  test "the codec refuses blocks the export rules out" do
    place = %{"name" => "Example Coffee", "location" => %{"latitude" => 1, "longitude" => 2}}
    places = %{"type" => "places", "places" => [place]}
    done = %{"turn_id" => "t", "server_seq" => 1, "text" => "x"}

    assert :ok = Protocol.validate_server_payload("text_done", Map.put(done, "blocks", [places]))

    for blocks <- [
          [],
          [places, places],
          [%{"type" => "events", "events" => [place]}],
          [%{places | "places" => []}],
          [%{places | "places" => List.duplicate(place, ReplyBlocks.max_places() + 1)}],
          %{"type" => "places"}
        ] do
      for type <- ~w(text_done row) do
        payload =
          if type == "row",
            do: row_payload() |> Map.put("blocks", blocks),
            else: Map.put(done, "blocks", blocks)

        assert {:error, {:invalid_field, "blocks"}} =
                 Protocol.validate_server_payload(type, payload),
               "#{type} accepted blocks #{inspect(blocks)}"
      end
    end
  end

  # M56 §4.2: the call's one row when it ends, as the Mac hears it and as a
  # history page carries it: with its gist, and with its task list when the
  # gist could not be made.
  test "golden ended rows carry a call's gist or its task list, as row and history", %{
    protocol: protocol
  } do
    server = jsonl(@server_fixtures)
    ended? = &(get_in(&1, ["metadata", "call", "event"]) == "ended")

    assert %{"type" => "row", "kind" => "text", "metadata" => %{"call" => call}} =
             row = Enum.find(server, ended?)

    assert :ok = Protocol.validate_call_metadata(call)
    assert call["gist_status"] == "written"
    assert [sentence, _gist] = String.split(row["text"], "\n\n")
    assert sentence == "Voice call, 6 minutes"

    paged =
      server
      |> Enum.filter(&(&1["type"] == "history_page"))
      |> Enum.flat_map(& &1["messages"])
      |> Enum.find(ended?)

    assert %{"role" => "assistant", "kind" => "text", "media_refs" => []} = paged
    assert :ok = Protocol.validate_call_metadata(paged["metadata"]["call"])
    assert paged["metadata"]["call"]["gist_status"] == "failed"
    assert paged["content"] =~ ~r/\AVoice call, 2 minutes\n\n- Completed: /

    [_before, calls] = String.split(protocol, "### A Live call's rows", parts: 2)

    for key <- ~w(engine gist_status) do
      assert calls =~ "| `#{key}` |", "PROTOCOL.md has no row for call.#{key}"
    end
  end

  # M56 §4.6, §6: a version 2 cancel may stop a task that outlived its call,
  # named by its three ids; its acknowledgement is that task's done row.
  test "cancel publishes task_ref as a version 2 field, with a golden and its rows", %{
    schema: schema,
    protocol: protocol
  } do
    task_ref = schema["$defs"]["cancel"]["properties"]["task_ref"]

    assert task_ref["type"] == "object"
    assert task_ref["x-since-version"] == 2
    assert Enum.sort(task_ref["required"]) == ~w(call_uuid revision task_id)
    refute "task_ref" in schema["$defs"]["cancel"]["required"]

    golden =
      @client_fixtures
      |> jsonl()
      |> Enum.find(&(&1["type"] == "cancel" and Map.has_key?(&1, "task_ref")))

    assert %{"task_ref" => %{"call_uuid" => _uuid, "task_id" => _id, "revision" => _rev}} =
             golden

    server = jsonl(@server_fixtures)

    for event <- ~w(task_running task_done) do
      row = Enum.find(server, &(get_in(&1, ["metadata", "call", "event"]) == event))
      assert %{"type" => "row", "kind" => "text"} = row, "no golden #{event} row"
      assert :ok = Protocol.validate_call_metadata(row["metadata"]["call"])
    end

    [_before, calls] = String.split(protocol, "### A Live call's rows", parts: 2)
    assert calls =~ "`task_running`"
    assert calls =~ "`task_done`"
    assert protocol =~ "`task_ref`"
  end

  test "the golden fixtures cover every event of the catalog by direction" do
    assert fixture_types(@client_fixtures) == MapSet.new(Protocol.client_events())
    assert fixture_types(@server_fixtures) == MapSet.new(Protocol.server_events())
  end

  test "the golden fixtures carry both history cursors and a search page" do
    client = jsonl(@client_fixtures)
    server = jsonl(@server_fixtures)

    assert Enum.any?(client, &(&1["type"] == "history_pull" and Map.has_key?(&1, "after_seq")))
    assert Enum.any?(client, &(&1["type"] == "history_pull" and Map.has_key?(&1, "before_seq")))
    assert Enum.any?(client, &(&1["type"] == "history_search" and Map.has_key?(&1, "before_seq")))
    assert Enum.any?(server, &Map.has_key?(&1, "next_before_seq"))
    assert Enum.any?(server, &(&1["type"] == "search_results" and &1["hits"] != []))
    assert Enum.any?(server, &(&1["reason"] == "unsupported_protocol_version"))
  end

  test "the golden server_hello advertises the module's live window" do
    {min, max} = Protocol.supported_version_range()
    hello = @server_fixtures |> jsonl() |> Enum.find(&(&1["type"] == "server_hello"))

    assert Map.drop(hello, ~w(primary_epoch role)) ==
             %{"type" => "server_hello", "min_version" => min, "max_version" => max}
  end

  # M75 D14: both hellos carry the primary epoch, optional on each, with a
  # golden of each and of the refusal of a client that has seen a higher one.
  test "the schema and the goldens carry the primary epoch on both hellos", %{
    schema: schema,
    protocol: protocol
  } do
    defs = schema["$defs"]
    epoch = %{"type" => "integer", "minimum" => 1, "maximum" => 18_446_744_073_709_551_615}

    for def <- ~w(client_hello server_hello) do
      assert Map.take(defs[def]["properties"]["primary_epoch"], ~w(type minimum maximum)) ==
               epoch,
             def

      refute "primary_epoch" in defs[def]["required"], def
    end

    client = jsonl(@client_fixtures)
    server = jsonl(@server_fixtures)
    assert Enum.any?(client, &(&1["type"] == "client_hello" and &1["primary_epoch"] > 0))
    assert Enum.any?(server, &(&1["type"] == "server_hello" and &1["primary_epoch"] > 0))

    stale = Enum.find(server, &(&1["reason"] == "stale_primary"))
    assert stale["message"] =~ ~r/^This engine is at epoch \d+; you have seen epoch \d+: /

    [_before, versioning] = String.split(protocol, "## Handshake state machine", parts: 2)
    [handshake, _after] = String.split(versioning, "## Rollout", parts: 2)
    assert handshake =~ "### Primary epoch"
    assert handshake =~ "keeps the highest"
    assert handshake =~ "`error: stale_primary`"
  end

  # M75: `server_hello.role` tells a desktop app whether the engine is the
  # primary, whose epoch it compares, or a device-role engine, whose it never
  # does; optional in the schema, since an older daemon sends none.
  test "server_hello names the engine's role, and the documentation the client rule", %{
    schema: schema,
    protocol: protocol
  } do
    server_hello = schema["$defs"]["server_hello"]
    assert server_hello["properties"]["role"]["enum"] == ~w(primary device)
    refute "role" in server_hello["required"]

    hello = @server_fixtures |> jsonl() |> Enum.find(&(&1["type"] == "server_hello"))
    assert hello["role"] in ~w(primary device)
    assert schema_errors(Map.delete(hello, "role"), ref("serverEvent"), schema) == []
    refute schema_errors(Map.put(hello, "role", "owner"), ref("serverEvent"), schema) == []

    [_before, epoch] = String.split(protocol, "### Primary epoch", parts: 2)
    [epoch, _after] = String.split(epoch, "## Rollout", parts: 2)
    assert epoch =~ "`role`"
    assert epoch =~ "from a `primary` only"
    assert epoch =~ "treated as `primary`"
  end

  test "every golden client frame decodes against the live protocol" do
    for line <- fixture_lines(@client_fixtures) do
      assert {:ok, %{type: type, payload: payload}} = Protocol.decode_client_event(line),
             "golden client frame did not decode: #{line}"

      assert Map.put(payload, "type", type) == Jason.decode!(line)
    end
  end

  test "every golden server frame is reproduced exactly by the encoder" do
    for frame <- jsonl(@server_fixtures) do
      assert {:ok, line} =
               Protocol.encode_server_event(frame["type"], Map.delete(frame, "type")),
             "encoder refused golden server frame: #{inspect(frame)}"

      assert String.ends_with?(line, "\n")
      assert Jason.decode!(line) == frame
    end
  end

  test "every golden fixture validates against the exported schema", %{schema: schema} do
    for frame <- jsonl(@client_fixtures) do
      assert schema_errors(frame, ref("clientEvent"), schema) == [], "client #{frame["type"]}"
    end

    for frame <- jsonl(@server_fixtures) do
      assert schema_errors(frame, ref("serverEvent"), schema) == [], "server #{frame["type"]}"
    end
  end

  # A gate that accepts everything proves nothing, so the drift the schema is
  # there to catch is exercised directly.
  test "the schema refuses frames that drift from the exported shape", %{schema: schema} do
    store_row = %{"server_seq" => 1, "role" => "assistant", "content" => "hi"}

    page = %{
      "type" => "history_page",
      "profile_id" => "main",
      "messages" => [store_row],
      "history_head_seq" => 1
    }

    refute schema_errors(page, ref("serverEvent"), schema) == []

    both = %{
      "type" => "history_pull",
      "profile_id" => "main",
      "after_seq" => 0,
      "before_seq" => 4,
      "limit" => 10
    }

    refute schema_errors(both, ref("clientEvent"), schema) == []

    attached = %{
      "type" => "msg",
      "client_msg_id" => "c",
      "profile_id" => "main",
      "text" => "look",
      "attach_ids" => ["photo"]
    }

    refute schema_errors(attached, ref("clientEvent"), schema) == []
    refute schema_errors(%{"type" => "ping"}, ref("clientEvent"), schema) == []
  end

  test "no exported field accepts an explicit null", %{schema: schema, protocol: protocol} do
    assert null_typed_paths(schema, "#") == []
    assert protocol =~ "never an explicit `null`"
  end

  test "documentation records the transport and the handshake", %{protocol: protocol} do
    assert protocol =~ "companion.sock"
    assert protocol =~ "`0600`"
    assert protocol =~ "65,536 bytes"
    assert protocol =~ "N/N-1"
    assert protocol =~ "handshake_required"
    assert protocol =~ "unexpected_client_hello"
    assert protocol =~ "Unicode scalar values"

    for type <- Protocol.client_events() ++ Protocol.server_events() do
      assert protocol =~ "| `#{type}` |", "PROTOCOL.md has no table row for #{type}"
    end
  end

  # approval_resolved reaches only the connections open when a card ends, so
  # a client that was away learns of it only by the card not coming back.
  test "documentation tells a client to drop the cards not sent after server_hello", %{
    protocol: protocol
  } do
    [_before, approvals] = String.split(protocol, "## Approvals", parts: 2)
    assert approvals =~ "When `server_hello` arrives, a client drops every card it shows"
  end

  defp minimal_client_payloads do
    %{
      "msg" => %{
        "client_msg_id" => "c",
        "profile_id" => "main",
        "text" => "hi",
        "attach_ids" => []
      },
      "command" => %{"client_msg_id" => "c", "profile_id" => "main", "name" => "help"},
      "cancel" => %{"profile_id" => "main", "client_msg_id" => "c"},
      "history_pull" => %{"profile_id" => "main", "limit" => 5},
      "history_search" => %{"profile_id" => "main", "query" => "q", "limit" => 5},
      "read_state" => %{"profile_id" => "main", "read_up_to_seq" => 0},
      "media_fetch" => %{"profile_id" => "main", "ref" => String.duplicate("a", 64)},
      "media_release" => %{"profile_id" => "main", "ref" => String.duplicate("a", 64)},
      "proposal_answer" => %{
        "client_msg_id" => "c",
        "profile_id" => "main",
        "proposal_id" => "cpr_1",
        "decision" => "confirm"
      }
    }
  end

  defp row_payload do
    %{
      "profile_id" => "main",
      "server_seq" => 1,
      "role" => "assistant",
      "text" => "x",
      "ts" => "2026-09-25T09:00:00Z",
      "media_refs" => []
    }
  end

  # A golden place back as the search's record: the same names, atom keyed.
  defp record(place) when is_map(place),
    do: Map.new(place, fn {key, value} -> {String.to_existing_atom(key), record(value)} end)

  defp record(value), do: value

  defp fixture_payloads(path) do
    path
    |> jsonl()
    |> Enum.uniq_by(& &1["type"])
    |> Enum.map(&{&1["type"], Map.delete(&1, "type")})
  end

  defp fixture_types(path), do: path |> jsonl() |> MapSet.new(& &1["type"])

  defp fixture_lines(path), do: path |> File.read!() |> String.split("\n", trim: true)

  defp jsonl(path), do: path |> fixture_lines() |> Enum.map(&Jason.decode!/1)

  defp ref(name), do: %{"$ref" => "#/$defs/#{name}"}

  defp null_typed_paths(schema, path) when is_map(schema) do
    Enum.flat_map(schema, fn {key, value} -> null_typed_paths(key, value, path) end)
  end

  defp null_typed_paths(schema, path) when is_list(schema) do
    schema
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} -> null_typed_paths(value, "#{path}/#{index}") end)
  end

  defp null_typed_paths(_scalar, _path), do: []

  defp null_typed_paths("type", "null", path), do: ["#{path}/type"]

  defp null_typed_paths("type", types, path) when is_list(types) do
    if "null" in types, do: ["#{path}/type"], else: []
  end

  defp null_typed_paths(key, value, path), do: null_typed_paths(value, "#{path}/#{key}")

  # A bounded validator for exactly the JSON Schema vocabulary this export uses.
  # Anything outside it fails loudly rather than passing unchecked, so extending
  # the schema with an unsupported keyword breaks this test instead of quietly
  # weakening the gate. Returns a list of problems; empty means valid.
  defp schema_errors(value, schema, root) when is_map(schema) do
    conditional_errors(schema, value, root) ++
      Enum.flat_map(Map.drop(schema, ["if", "then"]), &keyword_errors(&1, value, root))
  end

  defp conditional_errors(%{"if" => condition, "then" => branch}, value, root) do
    if schema_errors(value, condition, root) == [],
      do: schema_errors(value, branch, root),
      else: []
  end

  defp conditional_errors(_schema, _value, _root), do: []

  defp keyword_errors({"$ref", "#/$defs/" <> name}, value, root) do
    schema_errors(value, Map.fetch!(root["$defs"], name), root)
  end

  defp keyword_errors({"allOf", schemas}, value, root) do
    Enum.flat_map(schemas, &schema_errors(value, &1, root))
  end

  defp keyword_errors({"anyOf", schemas}, value, root) do
    if Enum.any?(schemas, &(schema_errors(value, &1, root) == [])),
      do: [],
      else: ["matched no anyOf branch"]
  end

  defp keyword_errors({"oneOf", schemas}, value, root) do
    case Enum.count(schemas, &(schema_errors(value, &1, root) == [])) do
      1 -> []
      matched -> ["matched #{matched} oneOf branches"]
    end
  end

  defp keyword_errors({"type", type}, value, _root) do
    if type?(value, type), do: [], else: ["expected #{type}, got #{inspect(value)}"]
  end

  defp keyword_errors({"required", keys}, value, _root) when is_map(value) do
    Enum.reject(keys, &Map.has_key?(value, &1)) |> Enum.map(&"missing #{&1}")
  end

  defp keyword_errors({"properties", properties}, value, root) when is_map(value) do
    Enum.flat_map(properties, fn {key, subschema} ->
      case Map.fetch(value, key) do
        {:ok, sub} -> Enum.map(schema_errors(sub, subschema, root), &"#{key}: #{&1}")
        :error -> []
      end
    end)
  end

  defp keyword_errors({"items", subschema}, value, root) when is_list(value) do
    Enum.flat_map(value, &schema_errors(&1, subschema, root))
  end

  defp keyword_errors({"minItems", min}, value, _root) when is_list(value) do
    if length(value) >= min, do: [], else: ["fewer than #{min} items"]
  end

  defp keyword_errors({"maxItems", max}, value, _root) when is_list(value) do
    if length(value) <= max, do: [], else: ["more than #{max} items"]
  end

  defp keyword_errors({"enum", allowed}, value, _root) do
    if value in allowed, do: [], else: ["#{inspect(value)} outside enum"]
  end

  defp keyword_errors({"const", expected}, value, _root) do
    if value == expected, do: [], else: ["#{inspect(value)} is not #{inspect(expected)}"]
  end

  defp keyword_errors({"minLength", min}, value, _root) when is_binary(value) do
    if String.length(value) >= min, do: [], else: ["shorter than #{min}"]
  end

  defp keyword_errors({"maxLength", max}, value, _root) when is_binary(value) do
    if String.length(value) <= max, do: [], else: ["longer than #{max}"]
  end

  defp keyword_errors({"pattern", pattern}, value, _root) when is_binary(value) do
    if Regex.match?(Regex.compile!(pattern), value), do: [], else: ["does not match #{pattern}"]
  end

  defp keyword_errors({"minimum", min}, value, _root) when is_number(value) do
    if value >= min, do: [], else: ["below #{min}"]
  end

  defp keyword_errors({"maximum", max}, value, _root) when is_number(value) do
    if value <= max, do: [], else: ["above #{max}"]
  end

  defp keyword_errors({keyword, _constraint}, _value, _root)
       when keyword in ~w(required properties items minItems maxItems minLength maxLength pattern
                          minimum maximum) do
    []
  end

  defp keyword_errors({keyword, _constraint}, _value, _root) do
    if keyword in @inert_keywords or String.starts_with?(keyword, "x-"),
      do: [],
      else: ["unsupported schema keyword #{keyword}"]
  end

  defp type?(value, "object"), do: is_map(value)
  defp type?(value, "array"), do: is_list(value)
  defp type?(value, "string"), do: is_binary(value)
  defp type?(value, "integer"), do: is_integer(value)
  defp type?(value, "number"), do: is_number(value)
  defp type?(value, "boolean"), do: is_boolean(value)
end
