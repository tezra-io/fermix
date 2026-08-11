defmodule FermixChannels.Channels.Signal.PlainTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Channels.Signal.Plain

  describe "render/1 golden set" do
    test "bold markers are removed and the text kept" do
      assert Plain.render("a **bold** claim") == "a bold claim"
    end

    test "italic markers are removed for both spellings" do
      assert Plain.render("an *emphasised* word") == "an emphasised word"
      assert Plain.render("an _emphasised_ word") == "an emphasised word"
    end

    test "strikethrough markers are removed" do
      assert Plain.render("~~dropped~~ plan") == "dropped plan"
    end

    test "a link becomes label then url" do
      assert Plain.render("see [the schedule](https://example.com/s)") ==
               "see the schedule: https://example.com/s"
    end

    test "a link url reaches the reader byte for byte" do
      url = "https://provider.example/place/abc?token=xyz&utm=brave"

      assert Plain.render("[Example Coffee](#{url})") == "Example Coffee: #{url}"
    end

    test "a heading becomes a bare line followed by a blank line" do
      assert Plain.render("## Best operators\nConch Republic runs daily.") ==
               "Best operators\n\nConch Republic runs daily."
    end

    test "a heading already followed by a blank line gains no second one" do
      assert Plain.render("## Best operators\n\nConch Republic runs daily.") ==
               "Best operators\n\nConch Republic runs daily."
    end

    test "bullets become bullet glyphs and keep their indent" do
      assert Plain.render("- alpha\n  - bravo\n* charlie") ==
               "• alpha\n  • bravo\n• charlie"
    end

    test "a fenced block keeps its body verbatim, indented, fences dropped" do
      input = "```elixir\ndefp a_b, do: **not bold**\n  :ok\n```"

      assert Plain.render(input) == "    defp a_b, do: **not bold**\n      :ok"
    end

    test "an unterminated fence still drops only the opening marker" do
      assert Plain.render("```\nkeep me") == "    keep me"
    end

    test "an inline code span loses its backticks and keeps its text" do
      assert Plain.render("run `mix test` now") == "run mix test now"
    end

    test "a blockquote survives as a plain prefixed line" do
      assert Plain.render("> Treat 18 hours as the minimum.") ==
               "> Treat 18 hours as the minimum."
    end

    test "a table becomes indented aligned rows" do
      input = """
      | Site | Depth |
      | --- | --- |
      | Molasses Reef | 25 ft |\
      """

      assert Plain.render(input) ==
               "    Site          | Depth\n    --------------+------\n    Molasses Reef | 25 ft"
    end
  end

  # Ported from the Telegram renderer's census: a permissive emphasis rule
  # deletes characters out of identifiers and URLs, which on a plain surface is
  # silent corruption rather than a visible stray marker.
  describe "render/1 flanking discipline" do
    test "snake_case identifiers stay literal" do
      assert Plain.render("call user_profile_cache here") == "call user_profile_cache here"
    end

    test "arithmetic asterisks stay literal" do
      assert Plain.render("cost is 2 * 3 * 4 dollars") == "cost is 2 * 3 * 4 dollars"
    end

    test "underscores inside a bare URL stay literal" do
      url = "https://floridakeys.noaa.gov/sanctuary_preservation_areas.html"

      assert Plain.render(url) == url
    end

    test "an unmatched marker is emitted literally" do
      assert Plain.render("a **dangling opener") == "a **dangling opener"
    end
  end

  describe "render/1 structure" do
    test "bold spans a soft line break inside one paragraph" do
      assert Plain.render("**Key Largo has the best\nconcentration of reefs.**") ==
               "Key Largo has the best\nconcentration of reefs."
    end

    test "nested emphasis leaves no residue" do
      assert Plain.render("**really *deep* wreck**") == "really deep wreck"
    end

    test "a link inside bold keeps the label and the url" do
      assert Plain.render("**[Ocean Pointe](https://ocean.example/) — Tavernier**") ==
               "Ocean Pointe: https://ocean.example/ — Tavernier"
    end

    test "text with no markup is returned unchanged" do
      text = "Paragraph one.\n\nParagraph two, with word-1-2 tokens."

      assert Plain.render(text) == text
    end
  end

  describe "rendered_length/1" do
    test "measures the rendered form, not the source markdown" do
      assert Plain.rendered_length("**bold**") == String.length("bold")
    end
  end
end
