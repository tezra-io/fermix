defmodule FermixChannels.Outbound.CloserScanTest.Reference do
  @moduledoc """
  The closer search exactly as it stood before it was extracted and indexed.

  Kept verbatim, with the only edit the ctx argument flattened to `links?`, so
  it can be diffed against the shipping implementation. It is the specification:
  the index is a cost change, not a behaviour change, and every answer must
  match this one byte for byte — including the answers nobody would defend, like
  an unmatched delimiter staying literal text.
  """

  def find_closer(text, marker, links?) do
    seek_closer(text, 0, marker, :binary.compile_pattern(candidate_bytes(marker, links?)))
  end

  defp candidate_bytes(marker, true), do: [<<marker_byte(marker)>>, "`", "["]
  defp candidate_bytes(marker, false), do: [<<marker_byte(marker)>>, "`"]

  defp seek_closer(text, pos, marker, candidates) do
    case :binary.match(text, candidates, scope: {pos, byte_size(text) - pos}) do
      :nomatch -> :none
      {at, _len} -> take_closer(text, at, marker, candidates)
    end
  end

  defp take_closer(text, at, marker, candidates) do
    case classify_candidate(text, at, marker) do
      {:closer, rest} -> {:ok, binary_part(text, 0, at), rest}
      {:skip, next} -> seek_closer(text, advanced!(at, next), marker, candidates)
    end
  end

  defp advanced!(at, next) when next > at, do: next

  defp advanced!(at, next) do
    raise "reference closer search made no progress at byte #{at} (next: #{next})"
  end

  defp classify_candidate(text, at, marker) do
    case :binary.at(text, at) do
      ?` -> skip_to(code_span_end(text, at), at)
      ?[ -> skip_to(link_end(text, at), at)
      _delimiter -> delimiter_candidate(text, at, marker)
    end
  end

  defp skip_to({:ok, next}, _at), do: {:skip, next}
  defp skip_to(:none, at), do: {:skip, at + 1}

  defp delimiter_candidate(text, at, marker) do
    run = run_length(text, at + 1, marker_byte(marker), 1)

    cond do
      run < byte_size(marker) -> {:skip, at + 1}
      inner_run?(run, marker) -> {:skip, at + run}
      closer?(text, at, marker) -> {:closer, tail_after(text, at, marker)}
      true -> {:skip, at + 1}
    end
  end

  defp inner_run?(run, marker), do: run > 1 and byte_size(marker) == 1

  defp closer?(text, at, marker) do
    at > 0 and not whitespace_byte?(:binary.at(text, at - 1)) and
      not alnum_start?(next_char(text, at, marker))
  end

  defp run_length(text, at, byte, run) when at < byte_size(text) do
    if :binary.at(text, at) == byte, do: run_length(text, at + 1, byte, run + 1), else: run
  end

  defp run_length(_text, _at, _byte, run), do: run

  defp code_span_end(text, at) do
    case :binary.match(text, "`", scope: {at + 1, byte_size(text) - at - 1}) do
      {close, 1} when close > at + 1 -> {:ok, close + 1}
      _other -> :none
    end
  end

  defp link_end(text, at) do
    with {close, 1} <- :binary.match(text, "]", scope: {at + 1, byte_size(text) - at - 1}),
         ?( <- byte_at(text, close + 1),
         {:ok, stop} <- url_end(text, close + 2, 0),
         true <- link_parts?(slice(text, at + 1, close), slice(text, close + 2, stop - 1)) do
      {:ok, stop}
    else
      _other -> :none
    end
  end

  defp url_end(text, at, _depth) when at >= byte_size(text), do: :none

  defp url_end(text, at, depth) do
    case {:binary.at(text, at), depth} do
      {?), 0} -> {:ok, at + 1}
      {?), _depth} -> url_end(text, at + 1, depth - 1)
      {?(, _depth} -> url_end(text, at + 1, depth + 1)
      {_byte, _depth} -> url_end(text, at + 1, depth)
    end
  end

  defp link_parts?(label, url) do
    label != "" and url != "" and not String.contains?(label, "\n") and
      not Regex.match?(~r/\s/u, url)
  end

  defp marker_byte(marker), do: :binary.at(marker, 0)

  defp byte_at(text, at) when at < byte_size(text), do: :binary.at(text, at)
  defp byte_at(_text, _at), do: nil

  defp slice(text, from, to), do: binary_part(text, from, to - from)

  defp tail_after(text, at, marker) do
    from = at + byte_size(marker)
    binary_part(text, from, byte_size(text) - from)
  end

  defp next_char(text, at, marker) do
    from = at + byte_size(marker)
    binary_part(text, from, min(4, byte_size(text) - from))
  end

  defp alnum_start?(<<char::utf8, _rest::binary>>),
    do: Regex.match?(~r/^[\p{L}\p{N}]$/u, <<char::utf8>>)

  defp alnum_start?(_text), do: false

  defp whitespace_byte?(byte), do: byte in [?\s, ?\t, ?\n, ?\r]
end

defmodule FermixChannels.Outbound.CloserScanTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Channels.Telegram.Markdown
  alias FermixChannels.Outbound.CloserScan
  alias FermixChannels.Outbound.CloserScanTest.Reference
  alias FermixChannels.Outbound.Dialect

  @markers ["**", "~~", "*", "_"]

  # The shapes that separate a correct closer search from a plausible one: runs
  # that never close, doubled markers nested in single ones, delimiters that a
  # code span or link swallows, and the boundaries (text start, text end, a
  # multibyte neighbour) where an off-by-one hides.
  @shapes [
    "**a **a **a **a ",
    "*a *a *a *a ",
    "_a _a _a _a ",
    "~~a ~~a ~~a ~~a ",
    "*a **b** c*",
    "***a***",
    "**a*b*c**",
    "*a **b*",
    "a * b * c",
    "snake_case_id and _x_",
    "~~a ~~b~~",
    "`**x**`",
    "[a*b](https://x/y_(z))",
    "unbalanced [ bracket *a* here",
    "a backtick ` with no closer *b*",
    "*",
    "**",
    "*a",
    "a*",
    "_",
    "~~",
    "é**ü**ñ",
    "*é*",
    "line one *bold\nline two* end",
    "**a `b` [c](d) *e* ~~f~~ g**",
    "[label](url) *a",
    "*a `b *c` d*",
    "[a](b*c) *d*",
    "__a__ and **b**",
    "****",
    "*****a*****",
    "a ** b ** c",
    "[a*b](c) [d](e*f) *g*",
    "`a` *b* `c`"
  ]

  @alphabet ["*", "_", "~", "`", "[", "]", "(", ")", "a", "b", " ", "\n", "é"]
  @random_count 500
  @random_seed 20_260_905
  @max_random_length 60

  # Captured from the renderers as they stood before the closer search was
  # indexed. The index must not move a single byte of any of them.
  @goldens [
    {"**a **a **a **a ", "**a **a **a **a ", "**a **a **a **a "},
    {"*a *a *a *a ", "*a *a *a *a ", "*a *a *a *a "},
    {"_a _a _a _a ", "_a _a _a _a ", "_a _a _a _a "},
    {"~~a ~~a ~~a ~~a ", "~~a ~~a ~~a ~~a ", "~~a ~~a ~~a ~~a "},
    {"*a **b** c*", "<i>a <b>b</b> c</i>", "_a *b* c_"},
    {"***a***", "<b>*a</b>*", "**a**"},
    {"**a*b*c**", "<b>a*b*c</b>", "*a*b*c*"},
    {"*a **b*", "<i>a **b</i>", "_a **b_"},
    {"a * b * c", "a * b * c", "a * b * c"},
    {"snake_case_id and _x_", "snake_case_id and <i>x</i>", "snake_case_id and _x_"},
    {"~~a ~~b~~", "<s>a ~~b</s>", "~a ~~b~"},
    {"`**x**`", "<code>**x**</code>", "`**x**`"},
    {"[a*b](https://x/y_(z))", "<a href=\"https://x/y_(z)\">a*b</a>", "<https://x/y_(z)|a*b>"},
    {"unbalanced [ bracket *a* here", "unbalanced [ bracket <i>a</i> here",
     "unbalanced [ bracket _a_ here"},
    {"a backtick ` with no closer *b*", "a backtick ` with no closer <i>b</i>",
     "a backtick ` with no closer _b_"},
    {"*", "*", "*"},
    {"**", "**", "**"},
    {"*a", "*a", "*a"},
    {"a*", "a*", "a*"},
    {"_", "_", "_"},
    {"~~", "~~", "~~"},
    {"é**ü**ñ", "é**ü**ñ", "é**ü**ñ"},
    {"*é*", "<i>é</i>", "_é_"},
    {"line one *bold\nline two* end", "line one <i>bold\nline two</i> end",
     "line one _bold\nline two_ end"},
    {"**a `b` [c](d) *e* ~~f~~ g**",
     "<b>a <code>b</code> <a href=\"d\">c</a> <i>e</i> <s>f</s> g</b>",
     "*a `b` <d|c> _e_ ~f~ g*"},
    {"[label](url) *a", "<a href=\"url\">label</a> *a", "<url|label> *a"},
    {"*a `b *c` d*", "<i>a <code>b *c</code> d</i>", "_a `b *c` d_"},
    {"[a](b*c) *d*", "<a href=\"b*c\">a</a> <i>d</i>", "<b*c|a> _d_"},
    {"__a__ and **b**", "__a__ and <b>b</b>", "__a__ and *b*"},
    {"****", "", "****"},
    {"*****a*****", "<b>***a</b>***", "****a****"},
    {"a ** b ** c", "a ** b ** c", "a ** b ** c"},
    {"[a*b](c) [d](e*f) *g*", "<a href=\"c\">a*b</a> <a href=\"e*f\">d</a> <i>g</i>",
     "<c|a*b> <e*f|d> _g_"},
    {"`a` *b* `c`", "<code>a</code> <i>b</i> <code>c</code>", "`a` _b_ `c`"}
  ]

  # Measured on the development machine: 32 kB of stray bold openers rendered in
  # 10.8 s before the index and under 60 ms after, so a second is more than an
  # order of magnitude of headroom and cannot flake.
  @max_render_ms 1_000
  @attempts 3

  # The shape is asserted in reductions rather than wall-clock, because a
  # wall-clock ratio is not deterministic: a GC pause inside the renderer's own
  # iodata handling swung it between 4x and 11x on an idle machine, which is a
  # gate that fails clean product. Reductions count work, so they are immune to
  # load — 4x the bytes cost 15.979x before the index and 4.05x after, both
  # stable to three decimals across runs. 8x is the geometric midpoint, so the
  # bound is equidistant from linear and from quadratic.
  @max_work_growth 8

  describe "find/3 against the search it replaced" do
    test "answers identically for every suffix, marker and link mode in the corpus" do
      mismatches =
        for text <- corpus(), links? <- [true, false], reduce: [] do
          acc -> compare_text(text, links?, acc)
        end

      assert mismatches == [],
             "the indexed closer scan diverged from the reference on #{length(mismatches)} " <>
               "inputs, first few: #{inspect(Enum.take(mismatches, 5), limit: :infinity)}"
    end

    test "the corpus is the one the seed and shape list describe" do
      assert length(corpus()) == length(@shapes) + @random_count
      assert Enum.all?(corpus(), &(byte_size(&1) > 0))
      assert "**a **a **a **a " in corpus()
    end
  end

  describe "rendering shapes whose cost the index changed" do
    test "both renderers emit byte-identical output to their pre-index selves" do
      for {input, html, dialect} <- @goldens do
        assert Markdown.to_html(input) == html
        assert Dialect.render(input, spec()) == dialect
      end
    end

    test "a text with no marker at all still renders" do
      assert Markdown.to_html("plain prose, nothing to close") == "plain prose, nothing to close"
    end
  end

  describe "cost of a paragraph of unmatched openers" do
    @tag timeout: 120_000
    test "32 kB of stray bold openers renders well inside a second" do
      text = String.duplicate("**a ", 8_000)
      assert byte_size(text) == 32_000

      for {name, render} <- renderers() do
        elapsed = best_ms(fn -> render.(text) end)
        assert elapsed < @max_render_ms, "#{name} took #{elapsed} ms on 32 kB of stray openers"
      end
    end

    @tag timeout: 120_000
    test "quadrupling the input costs far less than the quadratic 16x of work" do
      small = String.duplicate("**a ", 2_000)
      large = String.duplicate("**a ", 8_000)

      for {name, render} <- renderers() do
        growth = work(fn -> render.(large) end) / work(fn -> render.(small) end)

        assert growth < @max_work_growth,
               "#{name} did #{Float.round(growth, 2)}x the work for 4x the bytes"
      end
    end
  end

  defp renderers do
    [
      {"to_html/1", &Markdown.to_html/1},
      {"rendered_utf16_length/1", &Markdown.rendered_utf16_length/1},
      {"entity_count/1", &Markdown.entity_count/1},
      {"Dialect.render/2", &Dialect.render(&1, spec())}
    ]
  end

  # Best of a few attempts: a render that is fast enough sometimes is fast
  # enough, and the minimum is the statistic a loaded CI box perturbs least.
  defp best_ms(fun) do
    1..@attempts
    |> Enum.map(fn _attempt -> fun |> :timer.tc() |> elem(0) end)
    |> Enum.min()
    |> Kernel./(1_000)
  end

  # Reductions consumed by one render, measured in a process of its own so the
  # count is that render's work and nothing else's.
  defp work(fun) do
    parent = self()
    ref = make_ref()

    spawn_link(fn ->
      fun.()
      {:reductions, count} = Process.info(self(), :reductions)
      send(parent, {ref, count})
    end)

    receive do
      {^ref, count} -> count
    after
      100_000 -> flunk("a render did not finish within 100 s, which is itself the regression")
    end
  end

  defp compare_text(text, links?, acc) do
    index = CloserScan.index(text, links?)

    for marker <- @markers, at <- offsets(text), reduce: acc do
      inner -> compare_suffix(text, index, links?, marker, at, inner)
    end
  end

  defp compare_suffix(text, index, links?, marker, at, acc) do
    suffix = binary_part(text, at, byte_size(text) - at)
    expected = Reference.find_closer(suffix, marker, links?)
    actual = scan(text, index, suffix, marker)

    if actual == expected, do: acc, else: [{text, links?, marker, at, expected, actual} | acc]
  end

  # A marker the text does not contain can never be opened in it, so `index/2`
  # builds no table for one — and the reference has to agree there is nothing to
  # find, since closing a run takes a marker byte. That equality is the proof
  # the omission is safe rather than a `fetch!` waiting to fire.
  defp scan(text, index, suffix, marker) do
    if String.contains?(text, marker), do: CloserScan.find(index, suffix, marker), else: :none
  end

  # Every real scan starts on a codepoint boundary, so those are the offsets an
  # inline pass can ask about.
  defp offsets(text), do: Enum.filter(0..byte_size(text), &boundary?(text, &1))

  defp boundary?(text, at) when at == byte_size(text), do: true
  defp boundary?(text, at), do: :binary.at(text, at) < 0x80 or :binary.at(text, at) >= 0xC0

  defp corpus, do: @shapes ++ random_strings()

  # A hand-rolled LCG rather than `:rand`, so the corpus is the same on every
  # OTP release and a failure reproduces from the seed alone.
  defp random_strings do
    {strings, _seed} =
      Enum.map_reduce(1..@random_count, @random_seed, fn _index, seed ->
        {length, seed} = next(seed, @max_random_length)
        build(length + 1, seed, [])
      end)

    strings
  end

  defp build(0, seed, acc), do: {IO.iodata_to_binary(acc), seed}

  defp build(left, seed, acc) do
    {pick, seed} = next(seed, length(@alphabet))
    build(left - 1, seed, [acc, Enum.at(@alphabet, pick)])
  end

  defp next(seed, modulo) do
    seed = rem(seed * 1_103_515_245 + 12_345, 2_147_483_648)
    {rem(div(seed, 65_536), modulo), seed}
  end

  # A dialect that spells every construct differently from the Telegram
  # renderer, so a golden that matched by coincidence in one would not in both.
  defp spec do
    %{
      bold: {"*", "*"},
      italic: {"_", "_"},
      strike: {"~", "~"},
      code_span: {"`", "`"},
      link: fn label, url -> "<#{url}|#{label}>" end,
      heading: fn text -> "*#{text}*" end,
      heading_blank_after: true,
      bullet: "• ",
      code_block: &Function.identity/1,
      table: &Dialect.align_rows/1
    }
  end
end
