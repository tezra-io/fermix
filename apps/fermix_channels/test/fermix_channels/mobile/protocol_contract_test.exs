defmodule FermixChannels.Mobile.ProtocolContractTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Protocol

  @priv_dir Application.app_dir(:fermix_core, "priv/mobile")
  @schema_path Path.join(@priv_dir, "protocol.schema.json")
  @protocol_path Path.join(@priv_dir, "PROTOCOL.md")
  @client_fixtures Path.join(@priv_dir, "fixtures/client_events.jsonl")
  @server_fixtures Path.join(@priv_dir, "fixtures/server_events.jsonl")
  @client_binary_fixtures Path.join(@priv_dir, "fixtures/client_binary_frames.jsonl")
  @server_binary_fixtures Path.join(@priv_dir, "fixtures/server_binary_frames.jsonl")

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

  defp jsonl(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
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
