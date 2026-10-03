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

  @priv_dir Application.app_dir(:fermix_core, "priv/companion")
  @schema_path Path.join(@priv_dir, "protocol.schema.json")
  @protocol_path Path.join(@priv_dir, "PROTOCOL.md")
  @client_fixtures Path.join(@priv_dir, "fixtures/client_events.jsonl")
  @server_fixtures Path.join(@priv_dir, "fixtures/server_events.jsonl")
  @mobile_schema_path Application.app_dir(:fermix_core, "priv/mobile/protocol.schema.json")
  @inert_keywords ~w($schema $id $defs title description)
  # The phone's `row` is this wire's `row` carrying the whole history message,
  # whose `media_refs` it always has.
  @phone_only_required %{"row" => ["media_refs"]}

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

    for def <- ~w(mediaRef linkPreviewCard) do
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
    assert hello == %{"type" => "server_hello", "min_version" => min, "max_version" => max}
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
      "read_state" => %{"profile_id" => "main", "read_up_to_seq" => 0}
    }
  end

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
