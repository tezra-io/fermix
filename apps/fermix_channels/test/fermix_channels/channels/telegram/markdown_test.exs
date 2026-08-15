defmodule FermixChannels.Channels.Telegram.MarkdownTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Channels.Telegram.Markdown

  describe "to_html/1 production defect census" do
    test "bold wrapping a link keeps the link inside the bold entity" do
      assert Markdown.to_html(
               "**[Ocean Pointe Suites](https://www.oceanpointesuites.com/) — Tavernier**"
             ) ==
               ~s(<b><a href="https://www.oceanpointesuites.com/">Ocean Pointe Suites</a> — Tavernier</b>)
    end

    test "heading containing a link renders as bold with the link intact" do
      input =
        "### 1. [Conch Republic Divers](https://conchrepublicdivers.com/) — best published schedule"

      assert Markdown.to_html(input) ==
               ~s(<b>1. <a href="https://conchrepublicdivers.com/">Conch Republic Divers</a> — best published schedule</b>)
    end

    test "italic nests inside bold" do
      assert Markdown.to_html("**really *deep* wreck**") == "<b>really <i>deep</i> wreck</b>"
    end

    test "underscores inside a bare URL stay literal" do
      url = "https://floridakeys.noaa.gov/sanctuary_preservation_areas.html"

      assert Markdown.to_html(url) == url
      refute Markdown.to_html(url) =~ "<i>"
    end

    test "snake_case identifiers stay literal" do
      assert Markdown.to_html("call user_profile_cache here") == "call user_profile_cache here"
    end

    test "arithmetic asterisks stay literal" do
      assert Markdown.to_html("cost is 2 * 3 * 4 dollars") == "cost is 2 * 3 * 4 dollars"
    end

    test "bold spans a soft line break inside one paragraph" do
      assert Markdown.to_html("**Key Largo has the best\nconcentration of reefs.**") ==
               "<b>Key Largo has the best\nconcentration of reefs.</b>"
    end

    test "a markdown table renders as one aligned pre block" do
      input = """
      | Site | Depth |
      | --- | --- |
      | Molasses Reef | 25 ft |
      | Christ Statue | 25 ft |\
      """

      assert Markdown.to_html(input) ==
               "<pre>Site          | Depth\n" <>
                 "--------------+------\n" <>
                 "Molasses Reef | 25 ft\n" <>
                 "Christ Statue | 25 ft</pre>"
    end

    test "a short blockquote renders plain" do
      assert Markdown.to_html("> Treat 18 hours as the bare minimum before flying.") ==
               "<blockquote>Treat 18 hours as the bare minimum before flying.</blockquote>"
    end

    test "a six line blockquote renders expandable" do
      input = "> one\n> two\n> three\n> four\n> five\n> six"

      assert Markdown.to_html(input) ==
               "<blockquote expandable>one\ntwo\nthree\nfour\nfive\nsix</blockquote>"
    end

    test "a horizontal rule collapses to a single blank line" do
      assert Markdown.to_html("before\n\n---\n\nafter") == "before\n\nafter"
    end

    test "a level four heading renders as bold" do
      assert Markdown.to_html("#### Deep heading") == "<b>Deep heading</b>"
    end
  end

  describe "to_html/1 inline rendering" do
    test "code span escapes its contents and parses nothing" do
      assert Markdown.to_html("`a < b & c`") == "<code>a &lt; b &amp; c</code>"
    end

    test "code span contents are not parsed as markdown" do
      assert Markdown.to_html("`**not bold**`") == "<code>**not bold**</code>"
    end

    test "bold may contain a code span" do
      assert Markdown.to_html("**run `mix test` now**") ==
               "<b>run <code>mix test</code> now</b>"
    end

    test "underscores around a whole word render italic" do
      assert Markdown.to_html("an _emphasised_ word") == "an <i>emphasised</i> word"
    end

    test "a link url keeps balanced parentheses" do
      assert Markdown.to_html("[Everglades](https://en.wikipedia.org/wiki/Everglades_(park))") ==
               ~s|<a href="https://en.wikipedia.org/wiki/Everglades_(park)">Everglades</a>|
    end

    test "a link with no closing parenthesis stays literal" do
      assert Markdown.to_html("[label](https://x.dev") == "[label](https://x.dev"
    end

    test "an unmatched bold delimiter stays literal" do
      assert Markdown.to_html("an unmatched ** stays literal") ==
               "an unmatched ** stays literal"
    end

    test "strikethrough renders as s" do
      assert Markdown.to_html("~~gone~~ now") == "<s>gone</s> now"
    end

    test "text nodes escape the four supported entities only" do
      assert Markdown.to_html(~s(a < b & c > d "e")) ==
               "a &lt; b &amp; c &gt; d &quot;e&quot;"
    end

    test "bullets become dot markers preserving indent" do
      assert Markdown.to_html("- one\n- two\n  * nested") == "• one\n• two\n  • nested"
    end

    test "numbered lists pass through" do
      assert Markdown.to_html("1. first\n2. second") == "1. first\n2. second"
    end

    test "headings strip bold markers instead of nesting bold in bold" do
      assert Markdown.to_html("## **Where to stay**") == "<b>Where to stay</b>"
    end

    test "blank line structure between blocks is preserved" do
      assert Markdown.to_html("one\n\ntwo") == "one\n\ntwo"
    end
  end

  describe "to_html/1 nested inline constructs" do
    test "italic containing bold keeps the inner bold whole" do
      assert Markdown.to_html("*a **b** c*") == "<i>a <b>b</b> c</i>"
    end

    test "underscore italic containing bold keeps the inner bold whole" do
      assert Markdown.to_html("_a **b** c_") == "<i>a <b>b</b> c</i>"
    end

    test "a star inside a code span does not close the italic around it" do
      assert Markdown.to_html("*outer `code*` still-italic*") ==
               "<i>outer <code>code*</code> still-italic</i>"
    end

    test "a star inside a link label does not close the italic around it" do
      assert Markdown.to_html("*a [b*](https://e.com/q) c*") ==
               ~s(<i>a <a href="https://e.com/q">b*</a> c</i>)
    end

    test "a run of three identical delimiters closes nothing and stays literal" do
      assert Markdown.to_html("___x___") == "___x___"
    end

    # The closer search used to rebuild the inner text per step and call
    # String.last/1 on it, which is cubic in an unmatched opener's tail: this
    # exact 4 kB input took ~25 s, on the hot path of every send and inside the
    # splitter's binary search, which re-renders the same text dozens of times.
    # The bound is deliberately loose — it catches a return of the algorithmic
    # defect (seconds), not a slow machine (it renders in tens of ms).
    test "4 kB of unmatched bold openers renders in well under a second" do
      text = String.duplicate("**a ", 1_000)

      {elapsed_us, html} = :timer.tc(fn -> Markdown.to_html(text) end)

      assert html == text
      assert elapsed_us < 1_000_000, "took #{div(elapsed_us, 1_000)} ms to render 4 kB"
    end
  end

  describe "to_html/1 fenced code" do
    test "a fenced block with a language carries the language class" do
      input = "```elixir\nname = \"hi\"\n```"

      assert Markdown.to_html(input) ==
               ~s(<pre><code class="language-elixir">name = &quot;hi&quot;</code></pre>)
    end

    test "a fenced block without a language carries no class" do
      assert Markdown.to_html("```\na < b\n```") == "<pre><code>a &lt; b</code></pre>"
    end

    test "a fenced block surrounded by prose keeps the surrounding blocks" do
      assert Markdown.to_html("before\n\n```\nx\n```\n\nafter") ==
               "before\n\n<pre><code>x</code></pre>\n\nafter"
    end
  end

  describe "rendered_utf16_length/1" do
    test "pure ASCII matches String.length" do
      text = "Ocean Pointe Suites, Tavernier"

      assert Markdown.rendered_utf16_length(text) == String.length(text)
    end

    test "astral plane characters count as surrogate pairs" do
      assert Markdown.rendered_utf16_length("😀😀") == 4
    end

    test "tags and entities do not count toward the rendered length" do
      assert Markdown.rendered_utf16_length("**bold**") == 4
      assert Markdown.rendered_utf16_length("a & b") == 5
    end
  end

  describe "entity_count/1" do
    test "counts the opening formatting tags the rendered html carries" do
      assert Markdown.entity_count(
               "**[Ocean Pointe Suites](https://www.oceanpointesuites.com/) — Tavernier**"
             ) == 2
    end

    test "plain text carries no entities" do
      assert Markdown.entity_count("just prose") == 0
    end
  end

  describe "extract_oversized_code/2" do
    test "an oversized fence is replaced by a placeholder line and returned" do
      body = String.duplicate("a", 5_000)
      input = "before\n\n```elixir\n#{body}\n```\n\nafter"

      assert {text, [block]} = Markdown.extract_oversized_code(input, 1_000)
      assert text == "before\n\n(full code attached as a file)\n\nafter"
      assert block.lang == "elixir"
      assert block.body == body
    end

    test "a fence within budget is left untouched" do
      input = "before\n\n```\nIO.puts(1)\n```\n\nafter"

      assert Markdown.extract_oversized_code(input, 1_000) == {input, []}
    end

    test "an oversized fence without a language reports a nil language" do
      input = "```\n#{String.duplicate("b", 2_000)}\n```"

      assert {"(full code attached as a file)", [%{lang: nil}]} =
               Markdown.extract_oversized_code(input, 100)
    end
  end
end
