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
  alias FermixCore.Realtime.Protocol

  @schema_path Application.app_dir(:fermix_core, "priv/realtime/protocol.schema.json")
  @client_fixtures Application.app_dir(:fermix_core, "priv/realtime/fixtures/client_events.jsonl")
  @server_fixtures Application.app_dir(:fermix_core, "priv/realtime/fixtures/server_events.jsonl")

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
