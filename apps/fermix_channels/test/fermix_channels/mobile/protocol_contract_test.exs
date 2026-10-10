defmodule FermixChannels.Mobile.ProtocolContractTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Management
  alias FermixChannels.Mobile.PairManager
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Mobile.Router
  alias FermixChannels.Mobile.SocketHandler
  alias FermixTestSupport.WireSchema

  @priv_dir Application.app_dir(:fermix_core, "priv/mobile")
  @schema_path Path.join(@priv_dir, "protocol.schema.json")
  @protocol_path Path.join(@priv_dir, "PROTOCOL.md")
  @client_fixtures Path.join(@priv_dir, "fixtures/client_events.jsonl")
  @server_fixtures Path.join(@priv_dir, "fixtures/server_events.jsonl")
  @client_binary_fixtures Path.join(@priv_dir, "fixtures/client_binary_frames.jsonl")
  @server_binary_fixtures Path.join(@priv_dir, "fixtures/server_binary_frames.jsonl")
  @pairing_links Path.join(@priv_dir, "fixtures/pairing_links.jsonl")

  setup_all do
    %{
      schema: @schema_path |> File.read!() |> Jason.decode!(),
      protocol: File.read!(@protocol_path)
    }
  end

  test "schema enums and versions match the live codec", %{schema: schema} do
    assert schema["x-protocol-version"] == Protocol.protocol_version()
    {min, max} = Protocol.supported_version_range()
    assert schema["x-supported-version-range"] == %{"min" => min, "max" => max}

    assert MapSet.new(get_in(schema, ["$defs", "clientEvent", "properties", "t", "enum"])) ==
             MapSet.new(Protocol.client_events())

    assert MapSet.new(get_in(schema, ["$defs", "serverEvent", "properties", "t", "enum"])) ==
             MapSet.new(Protocol.server_events())
  end

  test "every per-event def is reachable from a discriminator", %{schema: schema} do
    raw = File.read!(@schema_path)
    # The pairing link is not a frame: the owner's QR code carries it.
    structural = ~w(clientEvent serverEvent envelope pairingLink)
    per_event_defs = Map.keys(schema["$defs"]) -- structural

    for name <- per_event_defs do
      assert raw =~ "#/$defs/#{name}", "schema def #{name} is dangling"
    end
  end

  test "schema pins strengthened fields and framing", %{schema: schema} do
    defs = schema["$defs"]
    assert schema["x-frame-format"] == "uint32be-json-length + json-header + raw-bytes"
    assert schema["x-max-json-header-bytes"] == Protocol.max_header_bytes()
    assert schema["x-max-raw-chunk-bytes"] == Protocol.max_raw_chunk_bytes()
    assert "protocol_v" in defs["hello"]["required"]
    assert "min_version" in defs["hello_ack"]["required"]
    assert "max_version" in defs["hello_ack"]["required"]
    assert "sha256" in defs["attach_begin"]["required"]
    assert "client_msg_id" in defs["accepted"]["required"]
    assert "status" in defs["attach_status"]["required"]
    assert "ref" in defs["media_begin"]["required"]
    assert "index" in defs["media_chunk"]["required"]
    assert "sha256" in defs["media_end"]["required"]
    assert "approve_command" in defs["approval"]["required"]
    assert "deny_command" in defs["approval"]["required"]
    assert defs["approval"]["properties"]["approve_command"]["minLength"] == 1
    assert defs["approval"]["properties"]["approve_command"]["maxLength"] == 1_024
    assert defs["approval"]["properties"]["deny_command"]["minLength"] == 1
    assert defs["approval"]["properties"]["deny_command"]["maxLength"] == 1_024

    for field <- ~w(device_name model app_version) do
      assert defs["pair_request"]["properties"][field]["maxLength"] ==
               PairManager.max_text_bytes()
    end
  end

  # M51 D1: a pairing presents its attestation as the request's raw tail, and
  # is answered with the push salt the phone derives its push key from.
  test "schema pins the pairing request's attestation and the approval's push salt",
       %{schema: schema} do
    defs = schema["$defs"]
    request = defs["pair_request"]

    assert request["x-raw-bytes"] == true
    assert "platform" in request["required"] and "attestation" in request["required"]
    assert request["properties"]["platform"]["enum"] == ~w(ios android)
    assert request["x-max-attestation-chain-bytes"] == Protocol.max_attestation_chain_bytes()
    assert defs["attestation"]["properties"]["cert_lengths"]["maxItems"] == 6
    assert "push_salt" in defs["pair_approved"]["required"]
  end

  # D1(b) and D1(e): every error message is bounded, and every list of
  # candidates a phone is given keeps the same best-first few.
  test "schema pins the error message and candidate bounds the daemon keeps", %{schema: schema} do
    defs = schema["$defs"]
    message = defs["error"]["properties"]["message"]
    assert message["maxLength"] == 512
    assert message["x-max-bytes"] == 512

    for def <- ~w(hello_ack pair_approved) do
      assert defs[def]["properties"]["candidates"]["maxItems"] == SocketHandler.max_candidates()
    end

    link_candidates = defs["pairingLink"]["properties"]["candidates"]["contentSchema"]
    assert link_candidates["maxItems"] == SocketHandler.max_candidates()
  end

  test "schema pins the continuation frames and the event cap", %{schema: schema} do
    defs = schema["$defs"]
    cap = Protocol.max_event_bytes()
    parts = div(cap + Protocol.max_raw_chunk_bytes() - 1, Protocol.max_raw_chunk_bytes())

    assert schema["x-max-event-bytes"] == cap
    assert schema["x-max-event-parts"] == parts
    assert defs["event_part"]["x-raw-bytes"] == true
    assert defs["event_part"]["properties"]["count"]["maximum"] == parts
    assert defs["event_part"]["properties"]["index"]["maximum"] == parts - 1
    assert "event_part" in Protocol.server_events()
    refute "event_part" in Protocol.client_events()

    for def <- ~w(text_done row historyMessage) do
      assert defs[def]["properties"]["truncated"] == %{"const" => true}
    end
  end

  # The phone is told why a pairing ended in the words management uses, and
  # only in words a window that closes on a waiting phone can produce.
  test "pair_denied names every way a waiting pairing can end", %{schema: schema} do
    sent =
      [:denied, :expired, :cancelled, :device_disconnected]
      |> Enum.map(&(&1 |> PairManager.outcome_reason() |> Atom.to_string()))

    assert schema["$defs"]["pair_denied"]["properties"]["reason"]["enum"] == sent
    assert "timeout" in sent
  end

  # Absent optional fields are absent keys on this wire: every producer drops a
  # nil instead of shipping an explicit null, so no exported field may declare
  # `null` as an accepted type. Derived from the schema itself, so a field added
  # later joins the rule without anyone remembering to extend a list here.
  test "no exported field accepts an explicit null", %{schema: schema, protocol: protocol} do
    assert WireSchema.null_typed_paths(schema, "#") == []
    assert protocol =~ "optional by omission"
    assert protocol =~ "absent, never null"

    planted = %{
      "$defs" => %{
        "mediaRef" => %{"properties" => %{"filename" => %{"type" => ["string", "null"]}}}
      }
    }

    assert WireSchema.null_typed_paths(planted, "#") == [
             "#/$defs/mediaRef/properties/filename/type"
           ]

    for header <- client_headers() ++ server_headers() do
      assert WireSchema.null_values(header, "#") == [], "#{header["t"]} golden carries a null"
    end
  end

  test "every client golden frame decodes with the live codec" do
    for header <- jsonl(@client_fixtures) do
      assert header["t"] in Protocol.client_events()
      assert {:ok, %{type: type}} = Protocol.decode_client_frame(frame(header))
      assert type == header["t"]
    end
  end

  test "golden fixtures cover every catalog event exactly by direction" do
    client_types =
      jsonl(@client_fixtures)
      |> Enum.concat(Enum.map(jsonl(@client_binary_fixtures), & &1["header"]))
      |> Enum.map(& &1["t"])
      |> MapSet.new()

    server_types =
      jsonl(@server_fixtures)
      |> Enum.concat(Enum.map(jsonl(@server_binary_fixtures), & &1["header"]))
      |> Enum.map(& &1["t"])
      |> MapSet.new()

    assert client_types == MapSet.new(Protocol.client_events())
    assert server_types == MapSet.new(Protocol.server_events())
  end

  test "every server golden frame is reproduced by the live codec" do
    for header <- jsonl(@server_fixtures) do
      type = Map.fetch!(header, "t")
      seq = Map.fetch!(header, "seq")
      payload = Map.drop(header, ~w(v t seq))

      assert type in Protocol.server_events()
      assert {:ok, encoded} = Protocol.encode_server_frame(type, payload, seq)
      assert decode_header(encoded) == header
    end
  end

  test "binary fixture wrappers reconstruct and round-trip exact frames" do
    for fixture <- jsonl(@client_binary_fixtures) do
      bytes = Base.decode64!(fixture["bytes_b64"])
      assert {:ok, event} = Protocol.decode_client_frame(frame(fixture["header"], bytes))
      assert event.bytes == bytes
    end

    for fixture <- jsonl(@server_binary_fixtures) do
      header = fixture["header"]
      bytes = Base.decode64!(fixture["bytes_b64"])

      assert {:ok, encoded} =
               Protocol.encode_server_frame(
                 header["t"],
                 Map.drop(header, ~w(v t seq)),
                 header["seq"],
                 bytes
               )

      assert encoded == frame(header, bytes)
    end
  end

  # A phone concatenates a run's tails in index order and reads the result as
  # the event it names, with the run's `v` and its first frame's `seq`.
  test "every event_part run in the fixtures reassembles into an event the phone accepts",
       %{schema: schema} do
    runs =
      @server_binary_fixtures
      |> jsonl()
      |> Enum.filter(&(&1["header"]["t"] == "event_part"))
      |> Enum.chunk_by(& &1["header"]["count"])

    assert runs != []

    for [first | _rest] = run <- runs do
      assert Enum.map(run, & &1["header"]["index"]) == Enum.to_list(0..(length(run) - 1))
      assert Enum.map(run, & &1["header"]["count"]) == List.duplicate(length(run), length(run))
      seqs = Enum.map(run, & &1["header"]["seq"])
      assert seqs == Enum.to_list(hd(seqs)..(hd(seqs) + length(run) - 1))

      logical = run |> Enum.map(&Base.decode64!(&1["bytes_b64"])) |> IO.iodata_to_binary()
      event = Jason.decode!(logical)
      refute Map.has_key?(event, "v") or Map.has_key?(event, "seq")

      header = Map.merge(event, %{"v" => first["header"]["v"], "seq" => hd(seqs)})
      assert WireSchema.errors(header, WireSchema.ref("serverEvent"), schema) == []

      assert {:ok, _frame} =
               Protocol.encode_server_frame(event["t"], Map.delete(event, "t"), hd(seqs))
    end
  end

  test "every golden fixture validates against the vendored schema", %{schema: schema} do
    for header <- client_headers() do
      assert WireSchema.errors(header, WireSchema.ref("clientEvent"), schema) == [],
             "client #{header["t"]}"
    end

    for header <- server_headers() do
      assert WireSchema.errors(header, WireSchema.ref("serverEvent"), schema) == [],
             "server #{header["t"]}"
    end
  end

  # A gate that accepts everything proves nothing, so the drift the schema is
  # supposed to catch is exercised directly: a `history_page` carrying raw store
  # rows (no `ts`, no `media_refs`) is exactly what shipped before the projection.
  test "the schema refuses frames that drift from the exported shape", %{schema: schema} do
    store_row = %{
      "agent_id" => "agent",
      "owner_id" => "owner",
      "profile_id" => "main",
      "server_seq" => 12,
      "role" => "assistant",
      "content" => "Hello",
      "created_at" => "2026-08-12T12:00:00Z"
    }

    page = %{
      "profile_id" => "main",
      "messages" => [store_row],
      "next_after_seq" => 12,
      "history_head_seq" => 12
    }

    assert ["messages: " <> _reason | _rest] =
             server_errors(server_event("history_page", page), schema)

    refute server_errors(server_event("future_event", %{}), schema) == []
    refute server_errors(%{"v" => 2, "t" => "pong", "seq" => 0}, schema) == []
    assert server_errors(%{"v" => 2, "t" => "pong", "seq" => 1}, schema) == []

    bad_caps = %{"commands" => [%{"name" => "help"}], "max_media_bytes" => 1}
    hello_ack = server_event("hello_ack", Map.put(hello_ack_payload(), "caps", bad_caps))
    refute server_errors(hello_ack, schema) == []
  end

  test "the schema refuses what the daemon's bounds rule out", %{schema: schema} do
    candidate = %{"host" => "192.168.1.8", "interface" => "en0", "scope" => "lan"}
    crowded = Map.put(hello_ack_payload(), "candidates", List.duplicate(candidate, 17))
    refute server_errors(server_event("hello_ack", crowded), schema) == []

    refute server_errors(server_event("pair_denied", %{"reason" => "owner_denied"}), schema) == []
    refute server_errors(server_event("pair_denied", %{"reason" => "rate_limited"}), schema) == []

    preview = %{"in_reply_to" => 12, "url" => "https://e.com", "title" => "T"}
    long_site = Map.put(preview, "site", String.duplicate("é", 61))

    assert ["site: more than 120 bytes"] =
             server_errors(server_event("link_preview", long_site), schema)

    macs_row = %{
      "profile_id" => "main",
      "server_seq" => 3,
      "role" => "user",
      "text" => "hi",
      "ts" => "2026-09-27T09:00:00Z"
    }

    assert ["missing media_refs"] = server_errors(server_event("row", macs_row), schema)
    refute server_errors(server_event("text_done", text_done(false)), schema) == []
    assert server_errors(server_event("text_done", text_done(true)), schema) == []
  end

  # FEAT-5: the pairing link is the one thing a phone reads before it has a
  # session, so its format is exported, and pinned to what the daemon builds.
  describe "the pairing link" do
    test "the golden link decodes to its fields, which the schema accepts", %{schema: schema} do
      [%{"uri" => uri, "query" => query}] = jsonl(@pairing_links)

      assert String.starts_with?(uri, schema["$defs"]["pairingLink"]["x-uri-prefix"])
      assert %URI{scheme: "fermix", host: "pair", query: raw} = URI.parse(uri)
      assert URI.decode_query(raw) == query
      assert WireSchema.errors(query, WireSchema.ref("pairingLink"), schema) == []
      assert byte_size(Base.decode64!(query["gateway_pk"])) == 32
      assert byte_size(Base.decode64!(query["secret"])) == 32
      assert byte_size(Base.decode16!(query["tls_fp"], case: :lower)) == 32
    end

    test "the daemon builds exactly the golden link from its fields", %{schema: schema} do
      [%{"uri" => golden, "query" => query}] = jsonl(@pairing_links)

      assert {:ok, %{uri: uri}} = Management.begin_pairing(pairing_opts(query))
      assert uri == golden

      live = uri |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert WireSchema.errors(live, WireSchema.ref("pairingLink"), schema) == []
    end

    test "the schema refuses a link that drifts from the format", %{schema: schema} do
      [%{"query" => query}] = jsonl(@pairing_links)

      for {field, value} <- [
            {"v", "1"},
            {"v", "3"},
            {"profile", ""},
            {"candidates", "not json"},
            {"candidates", ~s({"host":"x"})},
            {"candidates", Jason.encode!(List.duplicate("192.168.1.8", 17))},
            {"tls_fp", String.upcase(query["tls_fp"])},
            {"gateway_pk", String.replace(query["gateway_pk"], "+", "-")},
            {"secret", String.trim_trailing(query["secret"], "=")},
            {"port", "0"}
          ] do
        refute WireSchema.errors(
                 Map.put(query, field, value),
                 WireSchema.ref("pairingLink"),
                 schema
               ) ==
                 [],
               "a pairing link with #{field}=#{value} was accepted"
      end

      refute WireSchema.errors(
               Map.delete(query, "profile"),
               WireSchema.ref("pairingLink"),
               schema
             ) ==
               [],
             "a pairing link with no profile was accepted"
    end
  end

  test "/healthz answers the protocol version this daemon serves", %{protocol: protocol} do
    conn = Router.call(Plug.Test.conn(:get, "/healthz"), Router.init([]))

    assert Jason.decode!(conn.resp_body) == %{
             "fermix" => "mobile",
             "v" => Protocol.protocol_version()
           }

    assert protocol =~ ~s({"fermix":"mobile","v":)
  end

  test "documentation records every close code the daemon sends", %{protocol: protocol} do
    for code <- ~w(1000 1002 1003 1008 1009 1011 4001 4003) do
      assert protocol =~ "| `#{code}` |", "PROTOCOL.md has no close-code row for #{code}"
    end
  end

  # D1(d): a phone branches on error.code, so every word the socket gives a
  # typed refusal is published, not only the ones someone remembered.
  test "documentation names every typed refusal code the socket sends", %{protocol: protocol} do
    [_before, errors] = String.split(protocol, "## Errors", parts: 2)
    [table, _after] = String.split(errors, "## Close codes", parts: 2)

    for code <- SocketHandler.typed_refusals() ++ ["media_fetch_backlog_full"] do
      assert table =~ "`#{code}`", "PROTOCOL.md's Errors table has no code #{code}"
    end
  end

  # approval_resolved reaches only the connections open when a card ends, so
  # a phone that was away learns of it only by the card not coming back.
  test "documentation tells a phone to drop the cards not sent after hello_ack", %{
    protocol: protocol
  } do
    [_before, approvals] = String.split(protocol, "## Approvals", parts: 2)
    assert approvals =~ "When `hello_ack` arrives, a client drops every card it shows"
  end

  test "documentation has a table row for every catalog event", %{protocol: protocol} do
    for type <- Protocol.client_events() ++ Protocol.server_events() do
      assert protocol =~ "| `#{type}` |", "PROTOCOL.md has no table row for #{type}"
    end

    for heading <- ["## Continuation frames", "## Pairing link", "## Approvals", "## Errors"] do
      assert protocol =~ heading
    end

    assert protocol =~ "fermix://pair?"
    assert protocol =~ "1 MiB"
  end

  test "documentation records the locked transport contract", %{protocol: protocol} do
    assert protocol =~ "FXM1"
    assert protocol =~ "32-bit unsigned big-endian"
    assert protocol =~ "60 KiB"
    assert protocol =~ "N/N-1"
    assert protocol =~ "IKpsk2"
    assert protocol =~ "approve_command"
    assert protocol =~ "deny_command"
    assert protocol =~ "preserving that direction's current transport nonce"
    refute protocol =~ "resetting that direction's transport nonce"
    assert protocol =~ "closes and reconnects"
    assert protocol =~ "never performs a unilateral time-based rekey"
  end

  test "documentation records the push payload the extension has to reproduce", %{
    protocol: protocol
  } do
    assert protocol =~ "fermix-push-v1"
    assert protocol =~ "HKDF-SHA256"
    assert protocol =~ "apns_key_salt"
    assert protocol =~ "mutable-content"
    assert protocol =~ "ciphertext||tag"
    assert protocol =~ "push_vectors.json"
    assert File.exists?(Path.join(@priv_dir, "push_vectors.json"))
  end

  defp jsonl(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp client_headers do
    jsonl(@client_fixtures) ++ Enum.map(jsonl(@client_binary_fixtures), & &1["header"])
  end

  defp server_headers do
    jsonl(@server_fixtures) ++ Enum.map(jsonl(@server_binary_fixtures), & &1["header"])
  end

  defp server_event(type, payload) do
    Map.merge(payload, %{"v" => 2, "t" => type, "seq" => 1})
  end

  defp hello_ack_payload do
    %{
      "session_id" => "session",
      "min_version" => 2,
      "max_version" => 2,
      "profiles" => [%{"id" => "main", "name" => "Fermix"}],
      "candidates" => [],
      "history_head_seq" => 0,
      "read_up_to_seq" => 0,
      "caps" => %{"commands" => [], "max_media_bytes" => 1}
    }
  end

  defp server_errors(event, schema),
    do: WireSchema.errors(event, WireSchema.ref("serverEvent"), schema)

  defp text_done(truncated) do
    %{"turn_id" => "turn-1", "server_seq" => 1, "text" => "Hi", "truncated" => truncated}
  end

  # The inputs the daemon builds a pairing link from, recovered from a link.
  defp pairing_opts(query) do
    identity = %{
      gateway_public_key: Base.decode64!(query["gateway_pk"]),
      tls_fingerprint: Base.decode16!(query["tls_fp"], case: :lower)
    }

    window = %{
      session_id: "session",
      secret: Base.decode64!(query["secret"]),
      identity: identity,
      opened_at_ms: 0,
      expires_at_ms: PairManager.max_ttl_ms()
    }

    candidates =
      query["candidates"]
      |> Jason.decode!()
      |> Enum.map(&%{address: &1, interface: "en0", scope: :lan})

    [
      config: [enabled: true],
      pair_manager: :pair,
      whereis: fn FermixChannels.Mobile.Supervisor -> self() end,
      listener: :listener,
      open_pair: fn :pair -> {:ok, window} end,
      listener_info: fn :listener ->
        {:ok, {{0, 0, 0, 0}, String.to_integer(query["port"])}}
      end,
      discover: fn -> {:ok, candidates} end,
      host_label: fn -> query["name"] end,
      profile: query["profile"]
    ]
  end

  defp frame(header, bytes \\ <<>>) do
    json = Jason.encode!(header)
    <<byte_size(json)::32, json::binary, bytes::binary>>
  end

  defp decode_header(<<size::32, rest::binary>>) do
    <<json::binary-size(size), _bytes::binary>> = rest
    Jason.decode!(json)
  end
end
