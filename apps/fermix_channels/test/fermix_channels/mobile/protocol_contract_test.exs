defmodule FermixChannels.Mobile.ProtocolContractTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.PairManager
  alias FermixChannels.Mobile.Protocol

  @priv_dir Application.app_dir(:fermix_core, "priv/mobile")
  @schema_path Path.join(@priv_dir, "protocol.schema.json")
  @protocol_path Path.join(@priv_dir, "PROTOCOL.md")
  @client_fixtures Path.join(@priv_dir, "fixtures/client_events.jsonl")
  @server_fixtures Path.join(@priv_dir, "fixtures/server_events.jsonl")
  @client_binary_fixtures Path.join(@priv_dir, "fixtures/client_binary_frames.jsonl")
  @server_binary_fixtures Path.join(@priv_dir, "fixtures/server_binary_frames.jsonl")
  @inert_keywords ~w($schema $id $defs title description)

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
    structural = ~w(clientEvent serverEvent envelope)
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

  # Absent optional fields are absent keys on this wire: every producer drops a
  # nil instead of shipping an explicit null, so no exported field may declare
  # `null` as an accepted type. Derived from the schema itself, so a field added
  # later joins the rule without anyone remembering to extend a list here.
  test "no exported field accepts an explicit null", %{schema: schema, protocol: protocol} do
    assert null_typed_paths(schema, "#") == []
    assert protocol =~ "optional by omission"

    planted = %{
      "$defs" => %{
        "mediaRef" => %{"properties" => %{"filename" => %{"type" => ["string", "null"]}}}
      }
    }

    assert null_typed_paths(planted, "#") == ["#/$defs/mediaRef/properties/filename/type"]
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

  test "every golden fixture validates against the vendored schema", %{schema: schema} do
    for header <- client_headers() do
      assert schema_errors(header, ref("clientEvent"), schema) == [], "client #{header["t"]}"
    end

    for header <- server_headers() do
      assert schema_errors(header, ref("serverEvent"), schema) == [], "server #{header["t"]}"
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

    drifted = server_event("history_page", %{"profile_id" => "main", "messages" => [store_row]})
    assert ["messages: " <> _reason | _rest] = schema_errors(drifted, ref("serverEvent"), schema)

    refute schema_errors(server_event("future_event", %{}), ref("serverEvent"), schema) == []
    refute schema_errors(%{"v" => 1, "t" => "pong", "seq" => 0}, ref("serverEvent"), schema) == []
    assert schema_errors(%{"v" => 1, "t" => "pong", "seq" => 1}, ref("serverEvent"), schema) == []

    bad_caps = %{"commands" => [%{"name" => "help"}], "max_media_bytes" => 1}
    hello_ack = server_event("hello_ack", Map.put(hello_ack_payload(), "caps", bad_caps))
    refute schema_errors(hello_ack, ref("serverEvent"), schema) == []
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
    Map.merge(payload, %{"v" => 1, "t" => type, "seq" => 1})
  end

  defp hello_ack_payload do
    %{
      "session_id" => "session",
      "min_version" => 1,
      "max_version" => 1,
      "profiles" => [%{"id" => "main", "name" => "Fermix"}],
      "candidates" => [],
      "history_head_seq" => 0,
      "read_up_to_seq" => 0,
      "caps" => %{"commands" => [], "max_media_bytes" => 1}
    }
  end

  defp ref(name), do: %{"$ref" => "#/$defs/#{name}"}

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

  defp keyword_errors({"type", types}, value, _root) when is_list(types) do
    if Enum.any?(types, &type?(value, &1)), do: [], else: ["expected #{Enum.join(types, "|")}"]
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
       when keyword in ~w(required properties items minLength maxLength pattern minimum maximum) do
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

  defp frame(header, bytes \\ <<>>) do
    json = Jason.encode!(header)
    <<byte_size(json)::32, json::binary, bytes::binary>>
  end

  defp decode_header(<<size::32, rest::binary>>) do
    <<json::binary-size(size), _bytes::binary>> = rest
    Jason.decode!(json)
  end
end
