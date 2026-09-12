defmodule FermixChannels.Outbound.Dialect do
  @moduledoc """
  Rewrites model-authored Markdown into one chat platform's own markup dialect.

  Pure functions. No channel knowledge, no config, no I/O — a caller supplies a
  `t:spec/0` describing how its platform spells bold, italic, strikethrough,
  code, links, headings, bullets, code blocks and tables, and one walker serves
  every dialect (CHANNEL_LONGFORM_PRESENTATION §3.1, §8). This is the same
  parameterization the outbound `Splitter` uses for limits and measurers, so a
  channel is `{limit, measurer, dialect}` and nothing else.

  Telegram is deliberately NOT built on this: its dialect is an HTML subset with
  entity escaping, nesting rules and a 400-on-any-mistake wire, and
  `FermixChannels.Channels.Telegram.Markdown` owns that. What this module reuses
  is that renderer's *discipline*, not its code — with one exception, the closer
  scan, which is genuinely shared code: `FermixChannels.Outbound.CloserScan` is
  a pure parser with nothing to escape, both renderers ask it exactly the same
  question, and two copies of it could only drift apart.

  Rendering is two passes:

    * a **block** pass over line runs — fenced code (handed to the dialect
      verbatim), pipe tables, blockquote runs, ATX headings, bullets,
      paragraphs; and
    * an **inline** recursive-descent pass per block, precedence code span ->
      link -> bold -> strikethrough -> italic. A paragraph's internal single
      newlines do not terminate an inline construct, so emphasis spanning two
      wrapped lines still renders as one span.

  ## Flanking discipline (ported from the Telegram renderer)

  Intra-word emphasis is disallowed for **both** `*` and `_`: an opener whose
  preceding character is alphanumeric, or a closer whose following character is
  alphanumeric, stays literal text. CommonMark permits intra-word `*`, but model
  prose is full of `snake_case` identifiers, `2 * 3` arithmetic and bare URLs
  such as `.../sanctuary_preservation_areas.html`, which the permissive rule
  turns into mangled emphasis. Emphasis openers must also be followed
  immediately by non-whitespace and closers preceded immediately by
  non-whitespace; unmatched or non-flanking delimiters are emitted literally.

  Hunting a closer steps *over* the constructs nested inside the run rather than
  into them, so an inner construct is never torn in half: a code span and a link
  are skipped whole, and a run of two or more identical delimiters belongs to
  the doubled marker (`**`, `~~`) so it never closes a single-character italic.
  The search is *indexed* once per inline pass rather than walked once per
  opener — every candidate is classified exactly once and each scan is answered
  by a binary search — so an unmatched opener no longer rescans the whole
  remainder, which matters because this sits inside the outbound splitter's
  binary search, re-measuring the same text repeatedly.

  Inline nesting is bounded; past the depth cap the remaining inner text is
  emitted literally rather than parsed further.

  ## What this module does not do

  It never escapes text for the wire. Every dialect built on it is a plain-text
  markup where the platform's own markers are the only special characters, so
  there is nothing to escape and nothing to unescape; a dialect needing entity
  escaping is a different renderer, not a spec.
  """

  alias FermixChannels.Outbound.CloserScan

  @type wrap :: {String.t(), String.t()}

  @typedoc """
  How one platform spells the constructs this walker recognises.

    * `:bold` / `:italic` / `:strike` / `:code_span` — `{open, close}` markers
      placed around the rendered inner text; `{"", ""}` strips the construct.
    * `:link` — receives the rendered label and the raw URL.
    * `:heading` — receives the rendered heading text, returns one line.
    * `:heading_blank_after` — insert a blank line after a heading whose next
      source line is not already blank (dialects with no heading marker need the
      gap to keep the heading readable).
    * `:bullet` — the marker that replaces `-` / `*` list bullets, indent kept.
    * `:code_block` — receives the fenced block's lines, opening and closing
      fence included, and returns the lines to emit.
    * `:table` — receives the table's rows as already-plain cells and returns
      the lines to emit; `align_rows/1` builds the monospace form.
  """
  @type spec :: %{
          bold: wrap(),
          italic: wrap(),
          strike: wrap(),
          code_span: wrap(),
          link: (String.t(), String.t() -> String.t()),
          heading: (String.t() -> String.t()),
          heading_blank_after: boolean(),
          bullet: String.t(),
          code_block: ([String.t()] -> [String.t()]),
          table: ([[String.t()]] -> [String.t()])
        }

  # `:scan` is absent only in the seed `root/1` builds; `inline/2` puts the
  # index for the text it is about to walk there before anything reads it.
  @typep ctx :: %{
           :spec => spec(),
           :links => boolean(),
           :depth => non_neg_integer(),
           optional(:scan) => CloserScan.t()
         }

  @max_inline_depth 8

  @required_keys [
    :bold,
    :bullet,
    :code_block,
    :code_span,
    :heading,
    :heading_blank_after,
    :italic,
    :link,
    :strike,
    :table
  ]

  @alnum_pattern ~r/^[\p{L}\p{N}]$/u
  @bullet_pattern ~r/^([ \t]*)[-*][ \t]+(.*)$/u
  @fence_pattern ~r/^[ \t]*```([A-Za-z0-9_+.-]*)[ \t]*$/u
  # Boundary-only, and wider than the pattern above on purpose — see
  # `fence_line?/1`. A trailing `\r` is info-string content here, so a CRLF
  # document is still fenced correctly.
  @fence_line_pattern ~r/^[ \t]*`{3,}[^`]*$/u
  @heading_pattern ~r/^[ ]{0,3}\#{1,6}[ \t]+(.*?)[ \t]*\#*[ \t]*$/u
  @heading_bold_pattern ~r/\*\*([^*\n]+?)\*\*/u
  @quote_pattern ~r/^>[ ]?(.*)$/u
  @separator_row_pattern ~r/^[\s|:-]+$/u

  @doc """
  Renders `text` in the dialect described by `spec`.
  """
  @spec render(String.t(), spec()) :: String.t()
  def render(text, spec) when is_binary(text) and is_map(spec) do
    assert_spec!(spec)

    text
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> render_blocks(spec, [])
    |> Enum.join("\n")
  end

  @doc """
  Renders table `rows` as monospace-aligned lines: header, rule, body.

  Dialects wrap the result in whatever their platform spells "preformatted".
  """
  @spec align_rows([[String.t()]]) :: [String.t()]
  def align_rows([_first | _rest] = rows) when is_list(rows) do
    widths = column_widths(rows)
    [header | body] = Enum.map(rows, &render_row(&1, widths))
    rule = Enum.map_join(widths, "-+-", &String.duplicate("-", &1))
    [header, rule | body]
  end

  @doc """
  True when `line` opens or closes a fenced code block.

  CommonMark's rule, deliberately: three or more backticks, then an info string
  containing no backtick, to end of line. That is a WIDER test than
  `@fence_pattern` above, which additionally demands an info string this module
  can map to a platform language tag — and the width matters in both
  directions. Too narrow and a legitimate opener (```` ```c# ````, an info
  string after a space, an attribute list) goes unrecognised while its closing
  ```` ``` ```` still matches, so the closer opens a region that runs to
  end-of-text. Too wide and ```` ```mono``` ```` inline in a sentence — a code
  *span*, since the info string may not contain a backtick — opens a fence
  nothing closes. Either way the outbound splitter stops finding cut points and
  emits the remainder as one chunk the channel then refuses, which is why this
  question has one answer in one place.
  """
  @spec fence_line?(String.t()) :: boolean()
  def fence_line?(line) when is_binary(line), do: Regex.match?(@fence_line_pattern, line)

  defp assert_spec!(spec) do
    case Enum.reject(@required_keys, &Map.has_key?(spec, &1)) do
      [] -> :ok
      missing -> raise ArgumentError, "dialect spec is missing keys: #{inspect(missing)}"
    end
  end

  # -- Block pass --

  defp render_blocks([], _spec, acc), do: Enum.reverse(acc)

  defp render_blocks(lines, spec, acc) do
    {rendered, rest} = take_block(lines, spec)
    assert_block_progress!(lines, rest)
    render_blocks(rest, spec, Enum.reduce(rendered, acc, &[&1 | &2]))
  end

  defp assert_block_progress!(lines, rest) when length(rest) < length(lines), do: :ok

  defp assert_block_progress!(lines, _rest) do
    raise "dialect block pass made no progress at: #{inspect(hd(lines))}"
  end

  defp take_block(["" | rest], _spec), do: {[""], rest}

  defp take_block([line | rest] = lines, spec) do
    cond do
      fence_lang(line) != nil -> take_fence(lines, spec)
      quote_line?(line) -> take_quote(lines, spec)
      table_start?(line, rest) -> take_table(lines, spec)
      heading_content(line) != nil -> take_heading(lines, spec)
      bullet_line?(line) -> {[render_bullet(line, spec)], rest}
      true -> take_paragraph(lines, spec)
    end
  end

  defp take_fence([open | rest], spec) do
    {body, close, tail} = take_fence_body(rest, [])
    {spec.code_block.([open | body] ++ List.wrap(close)), tail}
  end

  defp take_fence_body([], acc), do: {Enum.reverse(acc), nil, []}

  defp take_fence_body([line | rest], acc) do
    if fence_lang(line) == "" do
      {Enum.reverse(acc), line, rest}
    else
      take_fence_body(rest, [line | acc])
    end
  end

  defp take_quote(lines, spec) do
    {quoted, tail} = Enum.split_while(lines, &quote_line?/1)
    {Enum.map(quoted, &render_quote_line(&1, spec)), tail}
  end

  defp render_quote_line(line, spec) do
    [_, content] = Regex.run(@quote_pattern, line)
    "> " <> inline(content, root(spec))
  end

  defp take_table([header, _separator | rest], spec) do
    {body, tail} = Enum.split_while(rest, &table_row?/1)
    {spec.table.(Enum.map([header | body], &table_cells/1)), tail}
  end

  # Cells land inside a preformatted block on most dialects, where markers would
  # show up literally, so a cell is always reduced to plain text.
  defp table_cells(row) do
    row
    |> String.trim()
    |> String.trim("|")
    |> String.split("|")
    |> Enum.map(&(&1 |> String.trim() |> strip_inline()))
  end

  defp column_widths(rows) do
    columns = rows |> Enum.map(&length/1) |> Enum.max()

    Enum.map(0..(columns - 1), fn index ->
      rows
      |> Enum.map(&(&1 |> Enum.at(index, "") |> String.length()))
      |> Enum.max()
    end)
  end

  defp render_row(cells, widths) do
    widths
    |> Enum.with_index()
    |> Enum.map_join(" | ", fn {width, index} ->
      cells |> Enum.at(index, "") |> String.pad_trailing(width)
    end)
  end

  # A `**bold**` run inside a heading would nest the dialect's own bold marker
  # inside itself, so the heading owns the emphasis and the inner run is dropped.
  defp take_heading([line | rest], spec) do
    rendered =
      line
      |> heading_content()
      |> String.replace(@heading_bold_pattern, "\\1")
      |> inline(root(spec))

    {[spec.heading.(rendered) | heading_gap(spec, rest)], rest}
  end

  defp heading_gap(%{heading_blank_after: false}, _rest), do: []
  defp heading_gap(_spec, []), do: []
  defp heading_gap(_spec, [next | _rest]), do: if(blank?(next), do: [], else: [""])

  defp render_bullet(line, spec) do
    [_, indent, content] = Regex.run(@bullet_pattern, line)
    indent <> spec.bullet <> inline(content, root(spec))
  end

  defp take_paragraph([first | rest], spec) do
    {more, tail} = take_paragraph_tail(rest, [])
    {[[first | more] |> Enum.join("\n") |> inline(root(spec))], tail}
  end

  defp take_paragraph_tail([], acc), do: {Enum.reverse(acc), []}

  defp take_paragraph_tail([line | rest] = lines, acc) do
    if new_block?(lines) do
      {Enum.reverse(acc), lines}
    else
      take_paragraph_tail(rest, [line | acc])
    end
  end

  defp new_block?([line | rest]) do
    line == "" or fence_lang(line) != nil or quote_line?(line) or
      table_start?(line, rest) or heading_content(line) != nil or bullet_line?(line)
  end

  # -- Block predicates --

  defp fence_lang(line) do
    case Regex.run(@fence_pattern, line) do
      [_, lang] -> lang
      nil -> nil
    end
  end

  defp heading_content(line) do
    case Regex.run(@heading_pattern, line) do
      [_, content] -> content
      nil -> nil
    end
  end

  defp quote_line?(line), do: Regex.match?(@quote_pattern, line)

  defp bullet_line?(line), do: Regex.match?(@bullet_pattern, line)

  defp table_row?(line), do: String.contains?(line, "|") and String.trim(line) != ""

  defp table_start?(line, [next | _rest]), do: table_row?(line) and separator_row?(next)
  defp table_start?(_line, []), do: false

  defp separator_row?(line) do
    String.contains?(line, "|") and String.contains?(line, "-") and
      Regex.match?(@separator_row_pattern, line)
  end

  defp blank?(line), do: String.trim(line) == ""

  # -- Inline pass --

  @spec root(spec()) :: ctx()
  defp root(spec), do: %{spec: spec, links: true, depth: 0}

  defp strip_inline(text), do: inline(text, root(plain_spec()))

  # Only the inline half is ever consulted through `strip_inline/1`; the block
  # keys are present so the spec satisfies `assert_spec!/1` unconditionally.
  defp plain_spec do
    %{
      bold: {"", ""},
      italic: {"", ""},
      strike: {"", ""},
      code_span: {"", ""},
      link: &plain_link/2,
      heading: &Function.identity/1,
      heading_blank_after: false,
      bullet: "• ",
      code_block: &Function.identity/1,
      table: &align_rows/1
    }
  end

  defp plain_link(label, url), do: label <> ": " <> url

  defp inline(text, %{depth: depth}) when depth >= @max_inline_depth, do: text

  # The closer index covers exactly the text this pass walks, so a nested pass
  # over an inner substring builds its own rather than inheriting this one.
  defp inline(text, ctx) do
    scan(text, nil, [], Map.put(ctx, :scan, CloserScan.index(text, ctx.links)))
  end

  defp scan("", _prev, acc, _ctx), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp scan(text, prev, acc, ctx) do
    case take_construct(text, prev, ctx) do
      {:ok, out, rest, next_prev} ->
        assert_inline_progress!(text, rest)
        scan(rest, next_prev, [out | acc], ctx)

      :none ->
        <<char::utf8, rest::binary>> = text
        scan(rest, <<char::utf8>>, [<<char::utf8>> | acc], ctx)
    end
  end

  defp assert_inline_progress!(text, rest) when byte_size(rest) < byte_size(text), do: :ok

  defp assert_inline_progress!(text, _rest) do
    raise "dialect inline pass made no progress at: #{inspect(text)}"
  end

  defp take_construct("`" <> rest, _prev, ctx), do: code_span(rest, ctx)
  defp take_construct("[" <> rest, _prev, %{links: true} = ctx), do: link(rest, ctx)
  defp take_construct("**" <> rest, prev, ctx), do: emphasis(rest, "**", :bold, prev, ctx)
  defp take_construct("~~" <> rest, prev, ctx), do: emphasis(rest, "~~", :strike, prev, ctx)
  defp take_construct("*" <> rest, prev, ctx), do: emphasis(rest, "*", :italic, prev, ctx)
  defp take_construct("_" <> rest, prev, ctx), do: emphasis(rest, "_", :italic, prev, ctx)
  defp take_construct(_text, _prev, _ctx), do: :none

  defp code_span(text, ctx) do
    case :binary.split(text, "`") do
      [inner, rest] when inner != "" -> {:ok, wrap(ctx.spec.code_span, inner), rest, "`"}
      _other -> :none
    end
  end

  defp link(text, ctx) do
    with [label, "(" <> target] <- :binary.split(text, "]"),
         {:ok, url, rest} <- split_url(target, "", 0),
         true <- CloserScan.link_parts?(label, url) do
      inner = inline(label, %{ctx | links: false, depth: ctx.depth + 1})
      {:ok, ctx.spec.link.(inner, url), rest, ")"}
    else
      _other -> :none
    end
  end

  # Parentheses inside a URL are balanced, not terminators — model output links
  # to `.../Everglades_(park)` often enough that the naive split truncates href.
  defp split_url("", _url, _depth), do: :none
  defp split_url(")" <> rest, url, 0), do: {:ok, url, rest}
  defp split_url(")" <> rest, url, depth), do: split_url(rest, url <> ")", depth - 1)
  defp split_url("(" <> rest, url, depth), do: split_url(rest, url <> "(", depth + 1)

  defp split_url(<<char::utf8, rest::binary>>, url, depth) do
    split_url(rest, url <> <<char::utf8>>, depth)
  end

  defp emphasis(text, marker, key, prev, ctx) do
    if opener?(text, prev) do
      close_emphasis(text, marker, key, ctx)
    else
      :none
    end
  end

  defp close_emphasis(text, marker, key, ctx) do
    case CloserScan.find(ctx.scan, text, marker) do
      {:ok, inner, rest} ->
        rendered = inline(inner, %{ctx | depth: ctx.depth + 1})
        {:ok, wrap(Map.fetch!(ctx.spec, key), rendered), rest, marker}

      :none ->
        :none
    end
  end

  defp opener?(text, prev), do: not whitespace_start?(text) and not alnum?(prev)

  defp wrap({open, close}, inner), do: open <> inner <> close

  defp alnum?(nil), do: false
  defp alnum?(char), do: Regex.match?(@alnum_pattern, char)

  defp whitespace_start?(<<char::utf8, _rest::binary>>), do: char in [?\s, ?\t, ?\n, ?\r]
  defp whitespace_start?(_text), do: true
end
