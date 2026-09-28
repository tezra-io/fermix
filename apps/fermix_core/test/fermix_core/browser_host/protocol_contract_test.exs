defmodule FermixCore.BrowserHost.ProtocolContractTest do
  @moduledoc """
  Guards the canonical wire-contract export under `priv/browser_host/` against
  the source of truth (`FermixCore.BrowserHost.Protocol`). The Mac app vendors
  the schema and fixtures pinned by checksum, so if these drift from the module
  the app ships against a wire the daemon no longer speaks.
  """

  use ExUnit.Case, async: true

  alias FermixCore.BrowserHost.Protocol

  @priv_dir Application.app_dir(:fermix_core, "priv/browser_host")
  @schema_path Path.join(@priv_dir, "protocol.schema.json")
  @protocol_path Path.join(@priv_dir, "PROTOCOL.md")
  @requests Path.join(@priv_dir, "fixtures/requests.jsonl")
  @responses Path.join(@priv_dir, "fixtures/responses.jsonl")
  @events Path.join(@priv_dir, "fixtures/events.jsonl")
  @inert_keywords ~w($schema $id $defs title description)

  setup_all do
    %{
      schema: @schema_path |> File.read!() |> Jason.decode!(),
      protocol: File.read!(@protocol_path)
    }
  end

  test "the schema's discriminators match the protocol module", %{schema: schema} do
    defs = schema["$defs"]

    assert defs["hostEvent"]["properties"]["type"]["enum"] ==
             ["client_hello" | Protocol.events()]

    assert defs["daemonFrame"]["properties"]["type"]["enum"] ==
             ["server_hello", "error" | Protocol.requests()]

    assert defs["hostError"]["properties"]["reason"]["enum"] == Protocol.host_errors()
    assert defs["error"]["properties"]["reason"]["enum"] == Protocol.daemon_errors()
    assert defs["page.act"]["properties"]["kind"]["enum"] == Protocol.act_kinds()
  end

  test "the schema's version window and bounds match the protocol module", %{schema: schema} do
    {min, max} = Protocol.supported_version_range()

    assert schema["x-protocol-version"] == Protocol.protocol_version()
    assert schema["x-supported-version-range"] == %{"min" => min, "max" => max}
    assert schema["x-max-line-bytes"] == Protocol.max_line_bytes()
    assert schema["x-max-message-chars"] == Protocol.max_message_chars()
    assert schema["x-max-reason-chars"] == Protocol.max_reason_chars()
    assert schema["x-max-nodes"] == Protocol.max_nodes()

    defs = schema["$defs"]
    assert defs["hostError"]["properties"]["message"]["maxLength"] == Protocol.max_message_chars()
    assert defs["availability"]["properties"]["reason"]["maxLength"] == Protocol.max_reason_chars()
    assert defs["page"]["properties"]["nodes"]["maxItems"] == Protocol.max_nodes()
  end

  test "every def is reachable from a discriminator" do
    raw = File.read!(@schema_path)
    schema = Jason.decode!(raw)

    for name <- Map.keys(schema["$defs"]) -- ["hostEvent", "daemonFrame", "response"] do
      assert raw =~ "#/$defs/#{name}\"", "schema def #{name} is defined but never referenced"
    end
  end

  test "each request def requires what the encoder requires", %{schema: schema} do
    for %{"id" => id, "type" => type} = frame <- request_frames(),
        field <- schema["$defs"][type]["required"] -- ["id", "type"] do
      payload = frame |> Map.drop(["id", "type"]) |> Map.delete(field)

      assert {:error, {:missing_field, ^field}} = Protocol.encode_request(id, type, payload),
             "the encoder writes #{type} without #{field}"
    end
  end

  test "each event def requires what the decoder requires", %{schema: schema} do
    for %{"type" => type} = frame <- jsonl(@events), type != "client_hello",
        field <- schema["$defs"][type]["required"] -- ["type"] do
      assert {:error, {:missing_field, ^field}} =
               Protocol.validate_event(type, frame |> Map.delete("type") |> Map.delete(field)),
             "the decoder accepts #{type} without #{field}"
    end
  end

  test "each result def requires what the decoder requires", %{schema: schema} do
    types = request_types()

    for %{"id" => id, "ok" => true, "result" => result} <- jsonl(@responses),
        field <- schema["$defs"][Map.fetch!(types, id) <> ".result"]["required"] do
      assert {:error, _reason} =
               Protocol.validate_result(Map.fetch!(types, id), Map.delete(result, field)),
             "the decoder accepts #{types[id]}'s result without #{field}"
    end
  end

  test "the golden fixtures cover every request, result, error and event" do
    requests = request_frames()
    assert MapSet.new(requests, & &1["type"]) == MapSet.new(Protocol.requests())
    assert MapSet.new(requests, & &1["kind"]) |> MapSet.delete(nil) == MapSet.new(Protocol.act_kinds())

    daemon = jsonl(@requests) |> Enum.reject(&Map.has_key?(&1, "id"))
    assert Enum.any?(daemon, &(&1["type"] == "server_hello"))
    assert MapSet.new(daemon, & &1["reason"]) |> MapSet.delete(nil) == MapSet.new(Protocol.daemon_errors())

    responses = jsonl(@responses)
    types = request_types()
    answered = for %{"ok" => true, "id" => id} <- responses, into: MapSet.new(), do: types[id]
    assert answered == MapSet.new(Protocol.requests())
    refused = for %{"ok" => false, "error" => error} <- responses, into: MapSet.new(), do: error["reason"]
    assert refused == MapSet.new(Protocol.host_errors())

    assert MapSet.new(jsonl(@events), & &1["type"]) ==
             MapSet.new(["client_hello" | Protocol.events()])
  end

  test "the golden server_hello advertises the module's live window" do
    {min, max} = Protocol.supported_version_range()
    hello = @requests |> jsonl() |> Enum.find(&(&1["type"] == "server_hello"))
    assert hello == %{"type" => "server_hello", "min_version" => min, "max_version" => max}
  end

  test "every golden request and daemon frame is reproduced exactly by the encoder" do
    for frame <- jsonl(@requests) do
      assert {:ok, line} = encode(frame), "encoder refused golden frame: #{inspect(frame)}"
      assert String.ends_with?(line, "\n")
      assert Jason.decode!(line) == frame
    end
  end

  test "every golden answer decodes, and its result fits the request its id names" do
    types = request_types()

    for line <- fixture_lines(@responses) do
      assert {:ok, {:response, id, outcome}} = Protocol.decode_host_frame(line),
             "golden answer did not decode: #{line}"

      case outcome do
        {:ok, result} -> assert Protocol.validate_result(Map.fetch!(types, id), result) == :ok
        {:error, error} -> assert error == Jason.decode!(line)["error"]
      end
    end
  end

  test "every golden event decodes against the live protocol" do
    for line <- fixture_lines(@events) do
      frame = Jason.decode!(line)

      case Protocol.decode_host_frame(line) do
        {:ok, {:hello, version}} -> assert frame["protocol_version"] == version
        {:ok, {:event, type, payload}} -> assert Map.put(payload, "type", type) == frame
        other -> flunk("golden event #{line} decoded as #{inspect(other)}")
      end
    end
  end

  test "every golden fixture validates against the exported schema", %{schema: schema} do
    types = request_types()

    for frame <- jsonl(@requests) do
      assert schema_errors(frame, ref("daemonFrame"), schema) == [], "daemon #{frame["type"]}"
    end

    for frame <- jsonl(@events) do
      assert schema_errors(frame, ref("hostEvent"), schema) == [], "event #{frame["type"]}"
    end

    for frame <- jsonl(@responses) do
      assert schema_errors(frame, ref("response"), schema) == [], "answer #{frame["id"]}"

      if frame["ok"] do
        result_ref = ref(Map.fetch!(types, frame["id"]) <> ".result")
        assert schema_errors(frame["result"], result_ref, schema) == [], "result #{frame["id"]}"
      end
    end
  end

  # A gate that accepts everything proves nothing, so the drift the schema and
  # the codec are there to catch is exercised directly.
  test "the schema and the codec refuse frames that drift from the export", %{schema: schema} do
    valued = %{"name" => "session", "domain" => "example.com", "value" => "secret"}
    cookies = %{"url" => "https://example.com/", "cookies" => [valued]}
    refute schema_errors(cookies, ref("cookies.get.result"), schema) == []
    assert {:error, _} = Protocol.validate_result("cookies.get", cookies)

    both = %{"id" => 1, "ok" => true, "result" => %{}, "error" => %{"reason" => "act_failed"}}
    refute schema_errors(both, ref("response"), schema) == []
    assert {:error, _} = Protocol.decode_host_frame(Jason.encode!(both))

    unknown = %{"id" => 1, "ok" => false, "error" => %{"reason" => "nope", "message" => "x"}}
    refute schema_errors(unknown, ref("response"), schema) == []
    assert {:error, _} = Protocol.decode_host_frame(Jason.encode!(unknown))

    silent = %{"type" => "availability", "available" => false}
    refute schema_errors(silent, ref("hostEvent"), schema) == []
    assert {:error, {:missing_field, "reason"}} = Protocol.decode_host_frame(Jason.encode!(silent))

    unobserved = %{"tab_id" => "t1", "url" => "https://example.com/", "observe" => true}
    refute schema_errors(Map.merge(unobserved, %{"id" => 1, "type" => "tab.navigate"}), ref("daemonFrame"), schema) == []
    assert {:error, _} = Protocol.encode_request(1, "tab.navigate", unobserved)

    assert {:error, _} =
             Protocol.encode_request(1, "tab.navigate", %{
               "tab_id" => "t1",
               "url" => "https://example.com/",
               "observe" => false,
               "snapshot" => %{"mode" => "full", "max_chars" => 10, "depth" => 1}
             })

    long = String.duplicate("x", Protocol.max_message_chars() + 1)
    over = %{"id" => 1, "ok" => false, "error" => %{"reason" => "act_failed", "message" => long}}
    assert {:error, _} = Protocol.decode_host_frame(Jason.encode!(over))

    refute schema_errors(%{"type" => "tab.moved"}, ref("hostEvent"), schema) == []
    assert {:error, {:unknown_event, "tab.moved"}} = Protocol.decode_host_frame(~s({"type":"tab.moved"}))
  end

  test "no exported field accepts an explicit null", %{schema: schema, protocol: protocol} do
    assert null_typed_paths(schema, "#") == []
    assert protocol =~ "never an explicit `null`"
  end

  test "documentation records the transport, the handshake and every row", %{protocol: protocol} do
    assert protocol =~ "browser_host.sock"
    assert protocol =~ "`0600`"
    assert protocol =~ "4,194,304 bytes"
    assert protocol =~ "N/N-1"
    assert protocol =~ "handshake_required"
    assert protocol =~ "attach_required"

    for type <- Protocol.requests() ++ Protocol.events() ++ Protocol.host_errors() do
      assert protocol =~ "| `#{type}` |", "PROTOCOL.md has no table row for #{type}"
    end

    for reason <- Protocol.daemon_errors() do
      assert protocol =~ "`#{reason}`", "PROTOCOL.md never names #{reason}"
    end
  end

  defp request_frames, do: @requests |> jsonl() |> Enum.filter(&Map.has_key?(&1, "id"))

  defp request_types, do: Map.new(request_frames(), &{&1["id"], &1["type"]})

  defp encode(%{"id" => id, "type" => type} = frame),
    do: Protocol.encode_request(id, type, Map.drop(frame, ["id", "type"]))

  defp encode(%{"type" => type} = frame),
    do: Protocol.encode_daemon_frame(type, Map.delete(frame, "type"))

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
      closed_errors(schema, value) ++
      Enum.flat_map(Map.drop(schema, ["if", "then", "additionalProperties"]), &keyword_errors(&1, value, root))
  end

  defp conditional_errors(%{"if" => condition, "then" => branch}, value, root) do
    if schema_errors(value, condition, root) == [],
      do: schema_errors(value, branch, root),
      else: []
  end

  defp conditional_errors(_schema, _value, _root), do: []

  defp closed_errors(%{"additionalProperties" => false} = schema, value) when is_map(value) do
    allowed = Map.keys(Map.get(schema, "properties", %{}))
    for key <- Map.keys(value), key not in allowed, do: "unexpected property #{key}"
  end

  defp closed_errors(_schema, _value), do: []

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

  defp keyword_errors({"maxItems", max}, value, _root) when is_list(value) do
    if length(value) <= max, do: [], else: ["more than #{max} items"]
  end

  defp keyword_errors({"minItems", min}, value, _root) when is_list(value) do
    if length(value) >= min, do: [], else: ["fewer than #{min} items"]
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
       when keyword in ~w(required properties items maxItems minItems minLength maxLength pattern
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
