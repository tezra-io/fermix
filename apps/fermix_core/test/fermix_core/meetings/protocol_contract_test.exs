defmodule FermixCore.Meetings.ProtocolContractTest do
  @moduledoc """
  Guards the canonical wire-contract export under `priv/meetbot/` against the
  source of truth (`FermixCore.Meetings.Sidecar.Frame`). The `fermix-meetbot`
  repo vendors `PROTOCOL.md` and the fixtures, so drift here means the sidecar
  is built against a contract the daemon no longer speaks — and, unlike a code
  change, drift produces no compiler error anywhere.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Meetings.Sidecar.Frame

  @protocol_md Application.app_dir(:fermix_core, "priv/meetbot/PROTOCOL.md")
  @control_fixtures Application.app_dir(
                      :fermix_core,
                      "priv/meetbot/fixtures/control_frames.jsonl"
                    )
  @audio_fixture Application.app_dir(:fermix_core, "priv/meetbot/fixtures/audio_frame.bin")

  setup_all do
    %{fixtures: fixture_frames()}
  end

  test "every golden control frame round-trips through the codec", %{fixtures: fixtures} do
    for %{"frame" => frame} <- fixtures do
      encoded = Frame.encode_control(frame)

      assert Frame.decode(encoded) == {:control, frame}
      assert Frame.decode_control!(encoded) == frame
    end
  end

  test "the fixtures cover exactly the types the codec knows, per direction", %{
    fixtures: fixtures
  } do
    for direction <- ["s2d", "d2s"] do
      covered =
        fixtures
        |> Enum.filter(&(&1["dir"] == direction))
        |> MapSet.new(& &1["frame"]["type"])

      known = MapSet.new(Frame.known_types(String.to_existing_atom(direction)))

      assert MapSet.difference(known, covered) |> MapSet.to_list() == [],
             "#{direction}: message type with no fixture"

      assert MapSet.difference(covered, known) |> MapSet.to_list() == [],
             "#{direction}: fixture for a type the codec does not know"
    end
  end

  test "the reserved signin message is deliberately absent from v1", %{fixtures: fixtures} do
    refute "signin" in Frame.known_types(:d2s)
    refute Enum.any?(fixtures, &(&1["frame"]["type"] == "signin"))
  end

  test "the golden audio payload is a valid 100 ms frame" do
    pcm = File.read!(@audio_fixture)

    assert byte_size(pcm) == 3_200
    assert Frame.validate_audio(pcm) == :ok
    assert Frame.decode(<<0x02, pcm::binary>>) == {:audio, pcm}
  end

  test "PROTOCOL.md states the caps and version the codec enforces" do
    doc = File.read!(@protocol_md)

    assert doc =~
             "| `0x01` | control | UTF-8 JSON object with a `\"type\"` string | " <>
               "#{Frame.max_control_bytes()} |"

    assert doc =~ "| `0x02` | audio | raw PCM s16le, 16 kHz, mono | #{Frame.max_audio_bytes()} |"
    assert doc =~ "currently **#{Frame.protocol_version()}**"
  end

  test "PROTOCOL.md documents every control type the codec knows" do
    doc = File.read!(@protocol_md)

    for type <- Frame.known_types(:s2d) ++ Frame.known_types(:d2s) do
      assert doc =~ ~s("type":"#{type}") or doc =~ "`#{type}`",
             "PROTOCOL.md never mentions the #{type} message"
    end
  end

  defp fixture_frames do
    @control_fixtures
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
