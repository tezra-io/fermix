defmodule FermixChannels.Channels.Slack.MrkdwnTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Channels.Slack.Mrkdwn

  describe "render/1 golden set" do
    test "bold collapses to a single asterisk pair" do
      assert Mrkdwn.render("a **bold** claim") == "a *bold* claim"
    end

    test "asterisk italic becomes underscore italic" do
      assert Mrkdwn.render("an *emphasised* word") == "an _emphasised_ word"
    end

    test "underscore italic stays underscore italic" do
      assert Mrkdwn.render("an _emphasised_ word") == "an _emphasised_ word"
    end

    test "strikethrough collapses to a single tilde pair" do
      assert Mrkdwn.render("~~dropped~~ plan") == "~dropped~ plan"
    end

    test "a link becomes Slack's angle form" do
      assert Mrkdwn.render("see [the schedule](https://example.com/s)") ==
               "see <https://example.com/s|the schedule>"
    end

    test "a link url keeps balanced parentheses" do
      assert Mrkdwn.render("[Park](https://en.wikipedia.org/wiki/Everglades_(park))") ==
               "<https://en.wikipedia.org/wiki/Everglades_(park)|Park>"
    end

    test "every heading level renders as one bold line" do
      assert Mrkdwn.render("# Top") == "*Top*"
      assert Mrkdwn.render("#### Deep heading") == "*Deep heading*"
    end

    test "a bold heading does not nest a second bold marker" do
      assert Mrkdwn.render("## **Best operators**") == "*Best operators*"
    end

    test "bullets become bullet glyphs and keep their indent" do
      assert Mrkdwn.render("- alpha\n  - bravo\n* charlie") ==
               "• alpha\n  • bravo\n• charlie"
    end

    test "a fenced block passes through untouched, contents unparsed" do
      input = "```elixir\ndefp a_b, do: **not bold**\n```"

      assert Mrkdwn.render(input) == input
    end

    test "an inline code span passes through untouched" do
      assert Mrkdwn.render("run `mix **test**` now") == "run `mix **test**` now"
    end

    test "a blockquote keeps its native marker" do
      assert Mrkdwn.render("> Treat 18 hours as the minimum.") ==
               "> Treat 18 hours as the minimum."
    end

    test "a table becomes an aligned monospace fence" do
      input = """
      | Site | Depth |
      | --- | --- |
      | Molasses Reef | 25 ft |\
      """

      assert Mrkdwn.render(input) ==
               "```\nSite          | Depth\n--------------+------\nMolasses Reef | 25 ft\n```"
    end
  end

  # Ported from the Telegram renderer's census: model prose is full of text that
  # a permissive emphasis rule mangles, and a mangled identifier or URL is a
  # user-visible defect on every channel, not just the one with a strict parser.
  describe "render/1 flanking discipline" do
    test "snake_case identifiers stay literal" do
      assert Mrkdwn.render("call user_profile_cache here") == "call user_profile_cache here"
    end

    test "arithmetic asterisks stay literal" do
      assert Mrkdwn.render("cost is 2 * 3 * 4 dollars") == "cost is 2 * 3 * 4 dollars"
    end

    test "underscores inside a bare URL stay literal" do
      url = "https://floridakeys.noaa.gov/sanctuary_preservation_areas.html"

      assert Mrkdwn.render(url) == url
    end

    test "an unmatched marker is emitted literally" do
      assert Mrkdwn.render("a **dangling opener") == "a **dangling opener"
    end
  end

  describe "render/1 structure" do
    test "bold spans a soft line break inside one paragraph" do
      assert Mrkdwn.render("**Key Largo has the best\nconcentration of reefs.**") ==
               "*Key Largo has the best\nconcentration of reefs.*"
    end

    test "italic nests inside bold" do
      assert Mrkdwn.render("**really *deep* wreck**") == "*really _deep_ wreck*"
    end

    test "a link inside bold keeps both" do
      assert Mrkdwn.render("**[Ocean Pointe](https://ocean.example/) — Tavernier**") ==
               "*<https://ocean.example/|Ocean Pointe> — Tavernier*"
    end

    test "text with no markup is returned unchanged" do
      text = "Paragraph one.\n\nParagraph two, with word-1-2 tokens."

      assert Mrkdwn.render(text) == text
    end
  end

  describe "rendered_length/1" do
    test "measures the rendered form, not the source markdown" do
      assert Mrkdwn.rendered_length("**bold**") == String.length("*bold*")
    end
  end
end
