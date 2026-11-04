defmodule FermixChannels.Mobile.Iroh.HelperProtocolContractTest do
  # The helper protocol's export (`fermix_core/priv/iroh_helper`) never drifts
  # from the codec: the fermix-iroh repository vendors it byte for byte.
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Iroh.HelperProtocol

  @dir Path.expand("../../../../../fermix_core/priv/iroh_helper", __DIR__)
  @fixtures Path.join(@dir, "fixtures")
  @endpoint_id "79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664"

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))
  defp line(name), do: name |> fixture() |> String.trim_trailing("\n")

  test "PROTOCOL.md declares the codec's protocol version" do
    assert File.read!(Path.join(@dir, "PROTOCOL.md")) =~
             "`protocol_version`, currently **#{HelperProtocol.protocol_version()}**"
  end

  test "every event fixture is one line, newline-terminated, and decodes" do
    assert {:ok, %{event: :hello, protocol_version: 3, iroh_version: "1.3.0"}} =
             HelperProtocol.decode_event(line("hello.json"))

    assert {:ok, %{event: :ready, endpoint_id: @endpoint_id}} =
             HelperProtocol.decode_event(line("ready.json"))

    assert {:ok, %{event: :relay, home_relay: "https://us1.relay.fermix.ai/", connected: true}} =
             HelperProtocol.decode_event(line("relay.json"))

    assert {:ok, %{event: :path, kind: :relay, endpoint_id: @endpoint_id}} =
             HelperProtocol.decode_event(line("path.json"))

    assert {:ok, %{event: :closed, endpoint_id: @endpoint_id}} =
             HelperProtocol.decode_event(line("closed.json"))

    assert {:ok, %{event: :refused, reason: :busy, endpoint_id: nil}} =
             HelperProtocol.decode_event(line("refused.json"))

    assert {:ok, %{event: :log, level: :warn}} = HelperProtocol.decode_event(line("log.json"))

    assert {:ok, %{event: :error, code: "key_invalid"}} =
             HelperProtocol.decode_event(line("error.json"))

    assert {:ok,
            %{
              event: :dialed,
              dial_id: "5f1c9a2e",
              kind: :relay,
              relay: "https://us1.relay.fermix.ai/"
            }} = HelperProtocol.decode_event(line("dialed.json"))

    assert {:ok, %{event: :dial_failed, dial_id: "5f1c9a2e", reason: :unreachable}} =
             HelperProtocol.decode_event(line("dial_failed.json"))

    assert {:ok, %{event: :dial_closed, dial_id: "5f1c9a2e"}} =
             HelperProtocol.decode_event(line("dial_closed.json"))

    for name <- File.ls!(@fixtures), String.ends_with?(name, ".json") do
      contents = fixture(name)
      assert String.ends_with?(contents, "\n") and not String.contains?(line(name), "\n"), name
    end
  end

  test "the codec's ops are the op fixtures" do
    relays = [
      %{"url" => "https://us1.relay.fermix.ai/", "quic_port" => 7842},
      %{"url" => "https://eu1.relay.fermix.ai/", "quic_port" => 7842}
    ]

    limits = %{
      max_connections: 1_024,
      max_streams_per_connection: 4,
      stream_receive_window: 262_144,
      connection_receive_window: 1_048_576,
      send_window: 1_048_576
    }

    start =
      HelperProtocol.start(
        "/Users/owner/.fermix/mobile/iroh_key",
        "/Users/owner/.fermix/mobile/bridge.sock",
        relays,
        limits
      )

    assert decoded(start) == Jason.decode!(fixture("start.json"))

    assert decoded(HelperProtocol.start_dial_only(relays, limits)) ==
             Jason.decode!(fixture("start_dial_only.json"))

    assert decoded(HelperProtocol.set_relays(relays)) == Jason.decode!(fixture("set_relays.json"))
    assert decoded(HelperProtocol.close(@endpoint_id)) == Jason.decode!(fixture("close.json"))

    socket = "/Users/owner/.fermix/mobile/dial-5f1c9a2e.sock"

    assert decoded(HelperProtocol.dial("5f1c9a2e", @endpoint_id, relays, socket)) ==
             Jason.decode!(fixture("dial.json"))

    direct = [%{"url" => "https://relay.invalid/", "quic_port" => 7842}]
    addrs = ["127.0.0.1:4100", "[::1]:4100"]

    assert decoded(HelperProtocol.dial("5f1c9a2e", @endpoint_id, direct, socket, addrs)) ==
             Jason.decode!(fixture("dial_direct.json"))

    assert decoded(HelperProtocol.shutdown()) == Jason.decode!(fixture("shutdown.json"))
  end

  test "a dial outside the contract fails loud, never reaches the helper" do
    relays = [%{"url" => "https://us1.relay.fermix.ai/", "quic_port" => 7842}]
    socket = "/home/owner/.fermix/mobile/dial-1.sock"

    for {id, peer, relays, socket, addrs} <- [
          {"UPPER", @endpoint_id, relays, socket, []},
          {"", @endpoint_id, relays, socket, []},
          {String.duplicate("d", 65), @endpoint_id, relays, socket, []},
          {"d1", "79b5", relays, socket, []},
          {"d1", @endpoint_id, [], socket, []},
          {"d1", @endpoint_id, [%{"url" => "http://r/", "quic_port" => 1}], socket, []},
          {"d1", @endpoint_id, [%{"url" => "https://r/", "quic_port" => 0}], socket, []},
          {"d1", @endpoint_id, List.duplicate(hd(relays), 9), socket, []},
          {"d1", @endpoint_id, relays, "relative.sock", []},
          {"d1", @endpoint_id, relays, socket, List.duplicate("127.0.0.1:1", 9)}
        ] do
      assert_raise ArgumentError, fn -> HelperProtocol.dial(id, peer, relays, socket, addrs) end
    end

    longest = String.duplicate("d", 63) <> "_"
    assert %{"dial_id" => ^longest} = HelperProtocol.dial(longest, @endpoint_id, relays, socket)
  end

  test "a close names one peer by its lowercase hex endpoint id, or fails loud" do
    for id <- [String.upcase(@endpoint_id), "79b5", @endpoint_id <> "00"] do
      assert_raise ArgumentError, fn -> HelperProtocol.close(id) end
    end
  end

  test "the bridge preamble fixture is a phone with the fixture key's endpoint id" do
    assert byte_size(fixture("bridge_preamble.bin")) == HelperProtocol.preamble_bytes()

    assert {:ok, :phone, @endpoint_id} =
             HelperProtocol.decode_preamble(fixture("bridge_preamble.bin"))

    {public, _secret} =
      :crypto.generate_key(:eddsa, :ed25519, :binary.list_to_bin(Enum.to_list(1..32)))

    assert Base.encode16(public, case: :lower) == @endpoint_id
  end

  test "a malformed, unknown or out-of-bounds event is refused, never guessed at" do
    for line <- [
          "not json",
          ~s({"op":"start"}),
          ~s({"event":"surprise"}),
          ~s({"event":"ready","endpoint_id":"79B5"}),
          ~s({"event":"path","endpoint_id":"#{@endpoint_id}","kind":"direct","relay":"https://x/"}),
          ~s({"event":"refused","reason":"tired","endpoint_id":null}),
          ~s({"event":"log","level":"warn","message":"#{String.duplicate("x", 513)}"}),
          ~s({"event":"dialed","dial_id":"D1","kind":"direct","relay":null}),
          ~s({"event":"dialed","dial_id":"d1","kind":"direct","relay":"https://x/"}),
          ~s({"event":"dialed","dial_id":"d1","kind":"relay","relay":null}),
          ~s({"event":"dial_failed","dial_id":"d1","reason":"tired"}),
          ~s({"event":"dial_closed"}),
          String.duplicate("x", HelperProtocol.max_line_bytes() + 1)
        ] do
      assert {:error, _reason} = HelperProtocol.decode_event(line), line
    end

    assert {:error, :invalid_preamble} =
             HelperProtocol.decode_preamble("FXB1" <> <<2>> <> <<0::256>>)

    assert {:error, :invalid_preamble} =
             HelperProtocol.decode_preamble("FXB2" <> <<1>> <> <<0::256>>)
  end

  defp decoded(op), do: op |> HelperProtocol.encode() |> IO.iodata_to_binary() |> Jason.decode!()
end
