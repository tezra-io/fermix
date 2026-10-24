defmodule FermixCore.Cues.PresetsTest do
  use ExUnit.Case, async: true

  alias FermixCore.Cues.Presets

  test "a section without a preset comes back as written" do
    section = %{kind: :local_push, token: "@keyring"}
    assert Presets.fill(section) == {:ok, section}
  end

  test "rss makes a feed poll and fills its interval" do
    assert {:ok, filled} = Presets.fill(%{preset: "rss", url: "https://example.org/feed.xml"})

    assert filled.kind == :feed
    assert filled.url == "https://example.org/feed.xml"
    assert is_integer(filled.interval) and filled.interval >= 60
  end

  test "every preset field can be overridden by the section" do
    assert {:ok, filled} = Presets.fill(%{preset: "rss", interval: 300, url: "https://e.test/a"})
    assert filled.interval == 300
  end

  test "an unknown preset is refused with the known names" do
    assert {:error, message} = Presets.fill(%{preset: "atom_feed"})
    assert message =~ ~s(unknown preset "atom_feed")
    assert message =~ "rss"
  end

  test "a kind that contradicts the preset is refused" do
    assert {:error, message} = Presets.fill(%{preset: "rss", kind: :stream})
    assert message =~ "preset rss makes a feed source"
  end

  test "the kind the preset names may be restated" do
    assert {:ok, %{kind: :feed}} = Presets.fill(%{preset: "rss", kind: :feed})
  end

  describe "bluesky_jetstream" do
    test "makes a stream on the public host, following posts by default" do
      assert {:ok, filled} =
               Presets.fill(%{preset: "bluesky_jetstream", dids: ["did:plc:abc123"]})

      assert filled.kind == :stream
      assert filled.url =~ ~r/^wss:/
      assert filled.collections == ["app.bsky.feed.post"]
      assert filled.dids == ["did:plc:abc123"]
    end

    # Whether dids are there at all is `Cues.Config.required_fields/3`'s rule,
    # the one both the config and the forms read; the preset checks their shape.
    test "leaves dids' presence to the config's rule" do
      for section <- [%{preset: "bluesky_jetstream"}, %{preset: "bluesky_jetstream", dids: []}] do
        assert {:ok, %{kind: :stream}} = Presets.fill(section)
      end
    end

    test "refuses a did that is not one" do
      assert {:error, message} = Presets.fill(%{preset: "bluesky_jetstream", dids: ["alice"]})
      assert message =~ "is not a DID"
    end
  end

  test "names lists every preset" do
    assert "rss" in Presets.names()
  end
end
