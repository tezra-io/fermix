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

  test "x_accounts makes a feed that polls every 5 minutes, with no address of its own" do
    assert {:ok, filled} = Presets.fill(%{preset: "x_accounts", handles: ["nasa"]})

    assert filled.kind == :feed
    assert filled.interval == 300
    refute Map.has_key?(filled, :url)
  end

  test "names lists every preset, and the engine ships no Bluesky preset" do
    assert Presets.names() == ["github", "rss", "x_accounts"]
    assert Presets.defaults("bluesky_jetstream") == :error
  end
end
