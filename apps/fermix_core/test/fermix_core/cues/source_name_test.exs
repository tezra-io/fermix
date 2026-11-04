defmodule FermixCore.Cues.SourceNameTest do
  # The name Fermix makes for a source left unnamed (M60 simpler setup §7, D2):
  # what it reads, as the owner would say it, then a free one of those names.
  use ExUnit.Case, async: true

  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Cues.SourceName

  describe "the name a section makes" do
    test "a feed or a stream takes its address's site" do
      cases = [
        {[preset: "rss", url: "https://news.ycombinator.com/rss"], "ycombinator"},
        {[preset: "rss", url: "https://News.YCombinator.com/rss"], "ycombinator"},
        {[kind: "feed", url: "https://lanternpress.example/feed.json"], "lanternpress"},
        # Under a country's top level, its registry level is skipped.
        {[preset: "rss", url: "https://www.harbourdaily.co.uk/news/rss.xml"], "harbourdaily"},
        {[preset: "rss", url: "https://blog.marrowfield.com.au/feed"], "marrowfield"},
        {[preset: "rss", url: "https://quillmere.io/feed.xml"], "quillmere"},
        {[preset: "rss", url: "https://news.tallowbrook.de/rss"], "tallowbrook"},
        {[kind: "stream", url: "wss://jetstream2.us-east.quillnet.network/subscribe"],
         "quillnet"},
        # A host with one label is its own site.
        {[kind: "feed", url: "https://localhost:8443/items"], "localhost"},
        # A label keeps letters and digits, a single hyphen for anything else,
        # and its accents dropped.
        {[kind: "feed", url: "https://news.tide_watch.org/"], "tide-watch"},
        {[kind: "feed", url: "https://bücher.example/feed"], "bucher"},
        {[kind: "feed", url: "https://feeds.kite--works.example.com/"], "example"},
        {[kind: "feed", url: "https://kite--works.com/"], "kite-works"}
      ]

      for {section, name} <- cases do
        assert SourceName.make(section, []) == {:ok, name}, inspect(section)
      end
    end

    test "an address with no site to name is named for its kind" do
      cases = [
        {[kind: "feed", url: "https://192.168.1.20/feed"], "feed"},
        {[kind: "stream", url: "wss://[::1]:9443/live"], "stream"},
        {[kind: "feed", url: "https://例え.jp/feed"], "feed"},
        {[kind: "feed", url: "not an address"], "feed"},
        {[kind: "stream"], "stream"},
        {[preset: "rss"], "feed"}
      ]

      for {section, name} <- cases do
        assert SourceName.make(section, []) == {:ok, name}, inspect(section)
      end
    end

    test "X accounts takes its first handle, as X spells it" do
      cases = [
        {[preset: "x_accounts", handles: ["nasa", "esa"]], "x-nasa"},
        {[preset: "x_accounts", handles: [" @NASA "]], "x-nasa"},
        {[preset: "x_accounts", handles: ["Orbit_Desk_7"]], "x-orbit-desk-7"},
        {[preset: "x_accounts", handles: []], "x-accounts"},
        {[preset: "x_accounts"], "x-accounts"}
      ]

      for {section, name} <- cases do
        assert SourceName.make(section, []) == {:ok, name}, inspect(section)
      end
    end

    test "GitHub, a program on this computer and any other webhook have their own words" do
      assert SourceName.make([preset: "github"], []) == {:ok, "github"}
      assert SourceName.make([kind: "local_push", daily_budget: 500], []) == {:ok, "scripts"}
      assert SourceName.make([kind: :local_push], []) == {:ok, "scripts"}

      assert SourceName.make([kind: "webhook", verify: "standard_webhooks"], []) ==
               {:ok, "webhook"}
    end

    test "a section that names neither a kind nor a known preset is a caller's mistake" do
      assert_raise ArgumentError, fn -> SourceName.make([url: "https://example.org"], []) end
      assert_raise ArgumentError, fn -> SourceName.make([preset: "pigeon"], []) end
    end
  end

  describe "a name already taken" do
    test "takes the first free number from 2" do
      assert SourceName.make([preset: "github"], ["github"]) == {:ok, "github-2"}
      assert SourceName.make([preset: "github"], ["github", "github-2"]) == {:ok, "github-3"}
      assert SourceName.make([preset: "github"], ["github-2", "scripts"]) == {:ok, "github"}

      assert SourceName.make([kind: "local_push"], ["scripts", "scripts-2", "scripts-4"]) ==
               {:ok, "scripts-3"}
    end

    test "stays within the name's length, a hyphen left at the cut dropped" do
      max = CuesConfig.max_name_length()
      label = String.duplicate("a", 63)
      section = [kind: "feed", url: "https://#{label}.com/feed"]

      assert SourceName.make(section, []) == {:ok, label}
      assert {:ok, name} = SourceName.make(section, [label])
      assert name == String.duplicate("a", max - 2) <> "-2"
      assert String.length(name) == max
      assert CuesConfig.valid_name?(name)

      cut_at_hyphen = String.duplicate("b", 61) <> "-c"
      section = [kind: "feed", url: "https://#{cut_at_hyphen}.com/feed"]

      assert SourceName.make(section, [cut_at_hyphen]) ==
               {:ok, String.duplicate("b", 61) <> "-2"}
    end

    test "is refused once as many names as a settings file holds sources are taken" do
      taken = ["github" | Enum.map(2..CuesConfig.max_sources(), &"github-#{&1}")]

      assert SourceName.make([preset: "github"], taken) ==
               {:error, "Every name Fermix tried for this source is taken. Give it a name."}

      # One fewer, and the last number is free.
      assert SourceName.make([preset: "github"], Enum.drop(taken, -1)) ==
               {:ok, "github-#{CuesConfig.max_sources()}"}
    end

    test "every name it makes is a valid name" do
      sections = [
        [preset: "rss", url: "https://news.ycombinator.com/rss"],
        [preset: "x_accounts", handles: ["Orbit_Desk_7"]],
        [kind: "feed", url: "https://bücher.example/feed"],
        [kind: "stream", url: "wss://[::1]:9443/live"],
        [preset: "github"]
      ]

      for section <- sections, taken <- [[], [elem(SourceName.make(section, []), 1)]] do
        assert {:ok, name} = SourceName.make(section, taken)
        assert CuesConfig.valid_name?(name), name
        refute name =~ "--"
        refute String.ends_with?(name, "-")
      end
    end
  end
end
