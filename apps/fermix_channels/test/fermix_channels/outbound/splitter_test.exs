defmodule FermixChannels.Outbound.SplitterTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Outbound.Splitter

  @sectioned """
  Here is the dive plan for three days in the Florida Keys, built around the
  wrecks you asked about and the operators that actually run night trips in
  August. Everything below assumes you are staying in Key Largo and driving
  down for the deeper sites.

  ## Wrecks worth the tanks

  The three big hulls sit within an hour of each other, and the current on all
  of them swings hard with the tide, so plan the deeper one first.

  - **Spiegel Grove** — 510 feet of landing ship dock in 130 feet of water. The
    superstructure tops out around 60 feet, so a recreational profile still
    gets you the bridge. See the [site notes](https://example.com/spiegel) for
    the mooring ball layout.
  - **USS Duane** — a 327-foot cutter sitting upright in 120 feet. Strong
    current, excellent pelagics, and the crow's nest is at 65 feet.
  - **Benwood** — shallow at 45 feet, broken up, and the best of the three for
    a second dive or a night dive. Details on the
    [wreck history](https://example.com/benwood) page.

  ## Best operators

  Three shops run the schedule you need, and only two of them do night trips
  midweek in August.

  - **Rainbow Reef** — two-tank wreck trips leave at 8am daily, and they run a
    Wednesday night dive on the Benwood. They advertise a lodging discount.
  - **Horizon Divers** — the only shop with a dedicated deep boat, which
    matters if you want back-to-back Spiegel Grove profiles.
  - **Conch Republic** — cheapest of the three and the most crowded. Fine for
    the shallow reef days, less good for the wrecks.

  ---

  ## Where to stay

  Key Largo splits into three clusters, and the one you pick decides how much
  driving you do at 6am with wet gear in the back seat.

  Anything on the ocean side between mile marker 100 and 103 puts you within
  ten minutes of every dock listed above. The bayside places are cheaper and
  quieter, but you will add twenty minutes to each morning. If you want the
  short version: book ocean side, book early, and skip the resorts that sit
  north of mile marker 106.

  ### Rough nightly rates

  Expect 190 to 240 a night for the ocean side places in August, and 130 to
  170 bayside. Anything under 120 is either a long drive or a bad review page.

  ## Gear and logistics

  Bring your own computer and a 7mm hood even in August, because the wreck
  boats run long surface intervals and the wind picks up after eleven. Tank
  rental is included on every trip listed above, but nitrox is an extra charge
  at all three shops and only two of them fill to 36 percent.

  - **Nitrox** — worth it on the Duane, pointless on the Benwood.
  - **Reef hook** — the Spiegel Grove mooring lines get crowded and a hook
    keeps you off other divers during the safety stop.
  - **Backup light** — mandatory for the night dive, and the shops rent them
    for eight dollars if you would rather not fly with batteries.

  ### Getting there

  Fly into Miami and drive the ninety minutes down, or fly into Key West and
  drive up if the fare is better. There is no useful transit, and the shops
  all expect you at the dock with your own car. Parking is free at every
  marina between mile marker 99 and 106, and the [tide tables](https://example.com/tides)
  matter more than the forecast for the deeper wrecks.

  ## What I still need from you

  Three things decide the rest of the plan:

  - Your certification level, because Spiegel Grove below 100 feet is not a
    recreational profile.
  - Whether you want the night dive, since that pins the shop to Rainbow Reef.
  - Your travel dates, because the August full moon week books out first and
    the lobster mini-season closes several sites entirely.
  """

  describe "option validation" do
    test "raises when :limit is missing" do
      assert_raise ArgumentError, ~r/:limit must be a positive integer/, fn ->
        Splitter.split("hello", [])
      end
    end

    test "raises when :limit is not a positive integer" do
      assert_raise ArgumentError, ~r/:limit/, fn -> Splitter.split("hello", limit: 0) end
      assert_raise ArgumentError, ~r/:limit/, fn -> Splitter.split("hello", limit: "4096") end
    end

    test "raises when :measure or :entity_count is not a 1-arity function" do
      assert_raise ArgumentError, ~r/:measure must be a 1-arity function/, fn ->
        Splitter.split("hello", limit: 10, measure: :length)
      end

      assert_raise ArgumentError, ~r/:entity_count must be a 1-arity function/, fn ->
        Splitter.split("hello", limit: 10, entity_count: fn _a, _b -> 0 end)
      end
    end
  end

  describe "trivial input" do
    test "empty and whitespace-only input return []" do
      assert Splitter.split("", limit: 100) == []
      assert Splitter.split("   \n\n  \t\n", limit: 100) == []
    end

    test "text within the limit is returned as one trimmed chunk" do
      assert Splitter.split("\n\nhello there\n\n", limit: 100) == ["hello there"]
    end
  end

  describe "sectioned long-form reply" do
    test "fixture is a realistic 3-5k char reply" do
      assert String.length(@sectioned) in 3_000..5_000
    end

    test "cuts land at section starts and never orphan a heading or lead-in" do
      chunks = Splitter.split(@sectioned, limit: 1_200)

      assert length(chunks) > 2
      assert Enum.all?(chunks, &(String.length(&1) <= 1_200))

      for chunk <- chunks do
        refute orphan_tail?(chunk), "chunk ends with a heading or ':' line:\n#{chunk}"
        assert starts_cleanly?(chunk), "chunk starts mid-sentence:\n#{chunk}"
      end

      # Every cut after the first opens a new section.
      for chunk <- tl(chunks) do
        assert String.starts_with?(chunk, "#"), "chunk does not open a section:\n#{chunk}"
      end
    end

    test "concatenation preserves every non-stripped character in order" do
      chunks = Splitter.split(@sectioned, limit: 1_200)

      assert normalize(drop_rule_lines(Enum.join(chunks, "\n\n"))) ==
               normalize(drop_rule_lines(@sectioned))
    end

    test "a tighter limit still opens every chunk at a boundary" do
      chunks = Splitter.split(@sectioned, limit: 600)

      assert length(chunks) > 4
      assert Enum.all?(chunks, &(String.length(&1) <= 600))
      assert Enum.all?(chunks, &starts_cleanly?/1)
      refute Enum.any?(chunks, &orphan_tail?/1)
    end
  end

  describe "chunk finalize" do
    test "a horizontal rule at a chunk's tail is stripped, blank lines with it" do
      text = """
      The first section runs long enough that the section boundary below is the
      only cut that fits inside the limit we pass, which is exactly the shape
      that used to strand a bare dash row at the end of a message.

      ---

      ## Second section

      And this is the body of the second section, which lands in its own chunk
      because the rule and the blank lines around it are gone.
      """

      chunks = Splitter.split(text, limit: 300)

      assert length(chunks) == 2
      assert String.ends_with?(hd(chunks), "at the end of a message.")
      refute Enum.any?(chunks, &String.contains?(&1, "---"))
      assert String.starts_with?(List.last(chunks), "## Second section")
    end

    test "a rule in the middle of a chunk is left verbatim" do
      text = "Above the rule.\n\n---\n\nBelow the rule."

      assert Splitter.split(text, limit: 500) == [text]
    end
  end

  describe "boundary ladder" do
    test "a single long paragraph cuts at sentence ends" do
      text = sentences(5_000)
      chunks = Splitter.split(text, limit: 800)

      assert length(chunks) > 5
      assert Enum.all?(chunks, &(String.length(&1) <= 800))
      assert Enum.all?(chunks, &String.ends_with?(&1, "."))
      assert normalize(Enum.join(chunks, " ")) == normalize(text)
    end

    test "a paragraph with no sentence punctuation cuts at whitespace" do
      text = comma_soup(3_000)
      chunks = Splitter.split(text, limit: 400)

      assert length(chunks) > 5
      assert Enum.all?(chunks, &(String.length(&1) <= 400))
      # No word was broken: rejoining on a single space reproduces the source.
      assert Enum.join(chunks, " ") == text
    end

    test "a text whose genuine last line is a heading keeps it" do
      text = @sectioned <> "\n\n## Coda\n"
      chunks = Splitter.split(text, limit: 1_200)

      assert String.ends_with?(List.last(chunks), "## Coda")
      refute Enum.any?(Enum.drop(chunks, -1), &orphan_tail?/1)
    end

    test "raises rather than looping when no cut can make progress" do
      assert_raise RuntimeError, ~r/at least one grapheme/, fn ->
        Splitter.split("some text that never fits", limit: 10, measure: fn _text -> 10_000 end)
      end
    end
  end

  describe "fenced code blocks" do
    test "a fence straddling the boundary moves the cut before the fence" do
      text =
        sentences(900) <>
          "\n\n```elixir\n" <>
          Enum.map_join(1..12, "\n", fn i -> "def handle_#{i}(arg), do: {:ok, arg}" end) <>
          "\n```\n\nAnd that is the whole module.\n"

      chunks = Splitter.split(text, limit: 1_000)

      assert length(chunks) > 1
      assert Enum.all?(chunks, &(String.length(&1) <= 1_000))

      for chunk <- chunks do
        assert rem(fence_count(chunk), 2) == 0, "chunk cut inside a fence:\n#{chunk}"
      end

      whole_fence = Enum.find(chunks, &String.contains?(&1, "```elixir"))
      assert String.contains?(whole_fence, "def handle_1(arg)")
      assert String.contains?(whole_fence, "def handle_12(arg)")
    end

    test "a fence that alone exceeds the limit is emitted unchanged as its own chunk" do
      body = Enum.map_join(1..20, "\n", fn i -> "line #{i} of a very long shell transcript" end)
      fence = "```sh\n" <> body <> "\n```"
      text = "Here is the log.\n\n" <> fence <> "\n\nThat is everything.\n"

      chunks = Splitter.split(text, limit: 200)

      assert ["Here is the log.", ^fence | rest] = chunks
      assert rest == ["That is everything."]
      assert String.length(fence) > 200
    end

    # An inline code span is not a fence — CommonMark forbids a backtick in the
    # info string, and both renderers agree. When the splitter disagreed, the
    # unmatched line opened a region that ran to end-of-text, every later cut
    # candidate was discarded, and the remainder went out as one atomic chunk
    # many times the limit — refused outright by Discord, whose limit IS the
    # platform cap.
    test "an inline code span does not open a fence" do
      text =
        "```mono``` is the flag you want.\n\n" <>
          sentences(900) <> "\n\nAnd that is the whole procedure.\n"

      chunks = Splitter.split(text, limit: 120)

      assert Enum.all?(chunks, &(String.length(&1) <= 120)),
             "over-limit chunk: #{inspect(Enum.max_by(chunks, &String.length/1))}"

      assert List.last(chunks) =~ "whole procedure"
    end

    # The mirror-image failure, and the one a narrower predicate causes: an
    # OPENER that goes unrecognised while its closer still matches leaves the
    # closer opening a region that runs to end-of-text. Same over-limit chunk,
    # reached from the other side — so the fence rule has to be CommonMark's
    # (any info string without a backtick), not the renderer's mappable-language
    # subset. `c#` is the everyday case; a space before the info string and an
    # attribute list are the others.
    for {label, info} <- [
          {"a language the renderer cannot map", "c#"},
          {"an info string behind a space", " sh"},
          {"an attribute-carrying info string", ~s(js title="a.js")}
        ] do
      test "a fence with #{label} is still a fence" do
        code = Enum.map_join(1..15, "\n", fn i -> "var line#{i} = compute(#{i});" end)
        prose = sentences(900)
        text = "Here is the snippet.\n\n```#{unquote(info)}\n#{code}\n```\n\n#{prose}\n"

        chunks = Splitter.split(text, limit: 200)
        prose_chunks = Enum.reject(chunks, &String.contains?(&1, "```"))

        assert Enum.all?(prose_chunks, &(String.length(&1) <= 200)),
               "over-limit prose chunk: #{inspect(Enum.max_by(prose_chunks, &String.length/1))}"

        fence_chunk = Enum.find(chunks, &String.contains?(&1, "```#{unquote(info)}"))
        assert String.contains?(fence_chunk, "var line1 =")
        assert String.contains?(fence_chunk, "var line15 =")
      end
    end

    # A fence may be longer than three backticks, and a CRLF document is still a
    # document. Both were protected before and must stay protected: the splitter
    # runs on raw channel text, which the renderer's own newline normalisation
    # never touches.
    test "four backticks and CRLF line endings still fence" do
      code = Enum.map_join(1..15, "\n", fn i -> "var line#{i} = compute(#{i});" end)

      four = "Lead in.\n\n````elixir\n#{code}\n````\n\nTrailing prose here.\n"

      assert Enum.find(Splitter.split(four, limit: 200), &String.contains?(&1, "````elixir")) =~
               "var line15 ="

      crlf =
        String.replace("Lead in.\n\n```c\n#{code}\n```\n\nTrailing prose here.\n", "\n", "\r\n")

      assert Enum.find(Splitter.split(crlf, limit: 200), &String.contains?(&1, "```c")) =~
               "var line15 ="
    end

    # A fence line may carry an info string and trailing whitespace, and may be
    # indented — the shapes the renderer recognises must still be protected.
    test "an indented fence with an info string is still a fence" do
      body = Enum.map_join(1..20, "\n", fn i -> "  line #{i} of an indented transcript" end)
      fence = "  ```sh \n" <> body <> "\n  ```"
      text = "Here is the log.\n\n" <> fence <> "\n\nThat is everything.\n"

      chunks = Splitter.split(text, limit: 200)

      # Chunks are trimmed, so the fence chunk loses its leading indent —
      # assert it stayed whole rather than byte-identical.
      assert hd(chunks) == "Here is the log."
      assert List.last(chunks) == "That is everything."

      fence_chunk = Enum.find(chunks, &String.contains?(&1, "```sh"))
      assert String.contains?(fence_chunk, "line 1 of an indented transcript")
      assert String.contains?(fence_chunk, "line 20 of an indented transcript")
    end
  end

  describe "entity budget" do
    test "an over-budget cut backs off along the same ladder" do
      text = links(40)
      entity_count = fn chunk -> chunk |> String.graphemes() |> Enum.count(&(&1 == "[")) end

      chunks =
        Splitter.split(text,
          limit: 100_000,
          entity_count: entity_count,
          entity_budget: 5
        )

      assert length(chunks) > 5
      assert Enum.all?(chunks, &(entity_count.(&1) <= 5))
      assert normalize(Enum.join(chunks, "\n")) == normalize(text)
    end

    test "without :entity_count the budget is ignored" do
      text = links(40)

      assert Splitter.split(text, limit: 100_000, entity_budget: 5) == [String.trim(text)]
    end
  end

  describe "custom measure" do
    test "a byte measure is honored over grapheme length" do
      text = String.duplicate("café ☕ résumé naïve ", 60)
      chunks = Splitter.split(text, limit: 200, measure: &byte_size/1)

      assert length(chunks) > 5
      assert Enum.all?(chunks, &(byte_size(&1) <= 200))
      refute Enum.all?(chunks, &(String.length(&1) <= 100))
      assert normalize(Enum.join(chunks, " ")) == normalize(text)
    end
  end

  # -- S2: streaming rotation primitive (CHANNEL_LONGFORM_PRESENTATION §6) -----

  describe "first_chunk/2" do
    test ":fits while the whole text is within the limit" do
      assert Splitter.first_chunk("", limit: 100) == :fits
      assert Splitter.first_chunk("  \n\n ", limit: 100) == :fits
      assert Splitter.first_chunk("short enough", limit: 100) == :fits
    end

    test "returns exactly the chunk split/2 would emit first" do
      for limit <- [600, 900, 1_200, 2_000] do
        {:chunk, chunk, _consumed} = Splitter.first_chunk(@sectioned, limit: limit)
        assert chunk == hd(Splitter.split(@sectioned, limit: limit))
      end
    end

    test "consumed is the byte offset the caller advances by" do
      {:chunk, chunk, consumed} = Splitter.first_chunk(@sectioned, limit: 1_200)

      remainder = binary_part(@sectioned, consumed, byte_size(@sectioned) - consumed)
      assert remainder == Enum.join(tl(Splitter.split(@sectioned, limit: 1_200)), "\n\n") <> "\n"
      refute String.starts_with?(remainder, "\n")
      assert String.trim(binary_part(@sectioned, 0, consumed)) == chunk
    end

    test "consumed absorbs the trimmed trailing rule line and its blank lines" do
      text = """
      The first section runs long enough that the section boundary below is the
      only cut that fits inside the limit we pass, which is exactly the shape
      that used to strand a bare dash row at the end of a message.

      ---

      ## Second section

      And this is the body of the second section.
      """

      {:chunk, chunk, consumed} = Splitter.first_chunk(text, limit: 250)

      refute chunk =~ "---"
      # The rule and its blank lines are BEHIND the offset: the remainder opens
      # at the heading, so a streaming caller never re-emits them.
      assert binary_part(text, consumed, byte_size(text) - consumed) =~ ~r/\A## Second section/
    end

    test "honors :measure and :entity_count exactly as split/2 does" do
      units = fn text -> byte_size(:unicode.characters_to_binary(text, :utf8, :utf16)) end
      emoji = String.duplicate("🌊 tide check — mooring ball notes. ", 40)

      {:chunk, chunk, consumed} = Splitter.first_chunk(emoji, limit: 200, measure: units)
      assert units.(chunk) <= 200
      assert consumed < byte_size(emoji)

      entity_count = fn chunk -> chunk |> String.graphemes() |> Enum.count(&(&1 == "[")) end

      {:chunk, linked, _consumed} =
        Splitter.first_chunk(links(40),
          limit: 100_000,
          entity_count: entity_count,
          entity_budget: 5
        )

      assert entity_count.(linked) <= 5
    end

    test "never cuts inside a fenced block" do
      text =
        sentences(900) <>
          "\n\n```elixir\n" <>
          Enum.map_join(1..12, "\n", fn i -> "def handle_#{i}(arg), do: {:ok, arg}" end) <>
          "\n```\n\nAnd that is the whole module.\n"

      {:chunk, chunk, consumed} = Splitter.first_chunk(text, limit: 1_000)

      assert rem(fence_count(chunk), 2) == 0
      remainder = binary_part(text, consumed, byte_size(text) - consumed)
      assert String.starts_with?(remainder, "```elixir")
    end

    test "property: the remainder is a clean multi-byte suffix and the chunk is its trim" do
      # Multi-byte on purpose: em dashes (3 bytes), accents (2), emoji (4) —
      # every offset returned must land on a grapheme boundary regardless.
      corpus = [
        @sectioned,
        String.duplicate("Résumé — naïve café ☕. Another sentence 🌊 here.\n\n", 60),
        String.duplicate("— 🌊 —\n", 300),
        sentences(4_000),
        comma_soup(3_000),
        links(40)
      ]

      for text <- corpus, limit <- [40, 137, 400, 1_000, 3_000] do
        case Splitter.first_chunk(text, limit: limit) do
          :fits ->
            assert String.length(String.trim(text)) <= limit

          {:chunk, chunk, consumed} ->
            assert consumed > 0
            assert consumed <= byte_size(text)
            remainder = binary_part(text, consumed, byte_size(text) - consumed)
            # A mid-grapheme cut makes the suffix invalid UTF-8 or re-splits a
            # grapheme cluster; both are caught by round-tripping graphemes.
            assert String.valid?(remainder)
            assert remainder |> String.graphemes() |> Enum.join() == remainder
            assert chunk == String.trim(binary_part(text, 0, consumed))
            assert chunk != ""
        end
      end
    end

    test "raises on the same option violations as split/2" do
      assert_raise ArgumentError, ~r/:limit must be a positive integer/, fn ->
        Splitter.first_chunk("hello", [])
      end

      assert_raise ArgumentError, ~r/:measure must be a 1-arity function/, fn ->
        Splitter.first_chunk("hello", limit: 10, measure: :length)
      end
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp orphan_tail?(chunk) do
    last = chunk |> String.split("\n") |> List.last()
    Regex.match?(~r/^\#{1,6} /, last) or String.ends_with?(last, ":")
  end

  defp starts_cleanly?(chunk) do
    Regex.match?(~r/^[\#\-*\[A-Z0-9]/, chunk)
  end

  defp fence_count(chunk) do
    chunk |> String.split("```") |> length() |> Kernel.-(1)
  end

  defp normalize(text) do
    text |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  defp drop_rule_lines(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r/^(-{3,}|\*{3,}|_{3,})$/, String.trim(&1)))
    |> Enum.join("\n")
  end

  defp sentences(min_length) do
    1..500
    |> Enum.map(fn i ->
      "Dive number #{i} put us over a patch of staghorn coral that has grown back since the last survey."
    end)
    |> take_until(min_length, " ")
  end

  defp comma_soup(min_length) do
    1..500
    |> Enum.map(fn i -> "item#{i}, another#{i}, and then some more filler#{i}," end)
    |> take_until(min_length, " ")
  end

  defp links(count) do
    1..count
    |> Enum.map(fn i -> "- [source #{i}](https://example.com/#{i}) covers one part of it." end)
    |> Enum.join("\n")
  end

  defp take_until(parts, min_length, joiner) do
    parts
    |> Enum.reduce_while([], fn part, acc ->
      acc = [part | acc]

      case acc |> Enum.join(joiner) |> String.length() do
        len when len >= min_length -> {:halt, acc}
        _len -> {:cont, acc}
      end
    end)
    |> Enum.reverse()
    |> Enum.join(joiner)
  end
end
