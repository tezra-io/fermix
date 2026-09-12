defmodule FermixChannels.Channels.Telegram.Markdown do
  @moduledoc """
  Renders model-authored Markdown into the HTML subset Telegram accepts under
  `parse_mode: "HTML"`.

  Telegram rejects an entire `sendMessage` with HTTP 400 when it sees an
  unsupported tag, unbalanced markup, or any named entity outside
  `&amp;lt; &amp;gt; &amp;amp; &amp;quot;`. This renderer therefore emits only
  `b`, `i`, `u`, `s`, `a`, `code`, `pre` and `blockquote`, escapes every text
  node itself, and never emits `<br>` (Telegram has no such tag — newlines are
  literal). `code`/`pre` may contain no other entity, so their bodies are only
  escaped, never parsed.

  Rendering is two passes:

    * a **block** pass over line runs — fenced code, pipe tables, blockquote
      runs, horizontal rules, ATX headings, bullets, paragraphs; and
    * an **inline** recursive-descent pass per block, with precedence
      code span -> link -> bold -> strikethrough -> italic. A paragraph's
      internal single newlines do not terminate an inline construct, so bold
      spanning two wrapped lines still renders as one entity.

  ## Deliberate deviation from CommonMark

  Intra-word emphasis is disallowed for **both** `*` and `_`: an opener whose
  preceding character is alphanumeric, or a closer whose following character
  is alphanumeric, stays literal text. CommonMark permits intra-word `*`, but
  model prose is full of `snake_case` identifiers, `2 * 3` arithmetic and bare
  URLs such as `.../sanctuary_preservation_areas.html`, which the permissive
  rule turns into stray `<i>` tags — and a stray tag is a 400 for the whole
  message, not a cosmetic defect. Emphasis openers must also be followed
  immediately by non-whitespace and closers preceded immediately by
  non-whitespace. Unmatched or non-flanking delimiters are emitted literally.

  ## Closer search steps over inner constructs

  Hunting the closer of an emphasis run is one left-to-right pass that steps
  *over* the constructs nested inside it rather than into them, so an inner
  construct can never be torn in half:

    * a code span (`` `…` ``) and a link (`[…](…)`) are skipped whole — a `*`
      inside either one is not a closer, exactly as the opener-side parser
      already treats them as atomic;
    * a run of two or more identical delimiters belongs to the doubled marker
      (`**` bold, `~~` strikethrough), so it never closes a single-character
      italic — `*a **b** c*` renders `<i>a <b>b</b> c</i>`, and the scan
      resumes past the whole run. A doubled marker's own run test is unchanged.

  The search is *indexed* once per inline pass rather than walked once per
  opener: `FermixChannels.Outbound.CloserScan` classifies every candidate in
  the text exactly once and answers each scan with a binary search, so an
  unmatched opener no longer rescans the whole remainder and a paragraph of
  stray delimiters costs O(n log n) instead of O(n²). That matters because the
  search sits on the hot path of every send *and* inside the outbound
  splitter's binary search, which re-measures the same text repeatedly. The
  dialect renderer shares that module, so the two parsers cannot drift apart.

  Inline nesting is bounded; past the depth cap the remaining inner text is
  emitted as escaped literal text rather than parsed further.
  """

  alias FermixChannels.Outbound.CloserScan

  @max_inline_depth 8
  @quote_expandable_lines 3
  @quote_expandable_chars 400
  @code_placeholder "(full code attached as a file)"

  @alnum_pattern ~r/^[\p{L}\p{N}]$/u
  @bullet_pattern ~r/^([ \t]*)[-*][ \t]+(.*)$/u
  @entity_open_pattern ~r/<(?:b|i|u|s|a|code|pre|blockquote)(?=[ >])/
  @fence_pattern ~r/^[ \t]*```([A-Za-z0-9_+.-]*)[ \t]*$/u
  @heading_pattern ~r/^[ ]{0,3}\#{1,6}[ \t]+(.*?)[ \t]*\#*[ \t]*$/u
  @heading_bold_pattern ~r/\*\*([^*\n]+?)\*\*/u
  @hr_pattern ~r/^[ \t]*(-{3,}|\*{3,}|_{3,})[ \t]*$/u
  @quote_pattern ~r/^>[ ]?(.*)$/u
  @separator_row_pattern ~r/^[\s|:-]+$/u
  @tag_pattern ~r/<[^>]*>/

  @root_inline %{links: true, depth: 0}

  @doc """
  Renders `text` as Telegram-flavoured HTML.
  """
  @spec to_html(String.t()) :: String.t()
  def to_html(text) when is_binary(text) do
    text
    |> normalize_newlines()
    |> String.split("\n")
    |> render_blocks([])
    |> Enum.join("\n")
  end

  @doc """
  UTF-16 code-unit length of the *rendered plain text* of `text`.

  Telegram measures message length in UTF-16 code units, so this is what a
  length budget must be computed against — tags and entities do not count.
  """
  @spec rendered_utf16_length(String.t()) :: non_neg_integer()
  def rendered_utf16_length(text) when is_binary(text) do
    text
    |> to_html()
    |> plain_text()
    |> utf16_units()
  end

  @doc """
  Counts the opening formatting tags the rendered HTML carries.

  Used against Telegram's per-message entity budget. A nested `pre > code`
  counts as two, which overstates by one — the budget is conservative on
  purpose.
  """
  @spec entity_count(String.t()) :: non_neg_integer()
  def entity_count(text) when is_binary(text) do
    @entity_open_pattern
    |> Regex.scan(to_html(text))
    |> length()
  end

  @doc """
  Removes fenced code blocks whose own rendered length exceeds `max`.

  Each removed block is replaced in the returned Markdown by a single
  placeholder line, and returned separately in document order so the caller
  can upload it as a file.
  """
  @spec extract_oversized_code(String.t(), pos_integer()) ::
          {String.t(), [%{lang: String.t() | nil, body: String.t()}]}
  def extract_oversized_code(text, max) when is_binary(text) and is_integer(max) and max > 0 do
    {lines, blocks} =
      text
      |> normalize_newlines()
      |> String.split("\n")
      |> extract_fences(max, [], [])

    {Enum.join(lines, "\n"), Enum.reverse(blocks)}
  end

  # -- Block pass --

  defp render_blocks([], acc), do: Enum.reverse(acc)

  defp render_blocks([line | rest], acc) when line != "" do
    if Regex.match?(@hr_pattern, line) do
      render_blocks(drop_leading_blanks(rest), ensure_blank_separator(acc))
    else
      consume_block([line | rest], acc)
    end
  end

  defp render_blocks(lines, acc), do: consume_block(lines, acc)

  defp consume_block(lines, acc) do
    {rendered, rest} = take_block(lines)
    assert_progress!(lines, rest)
    render_blocks(rest, Enum.reduce(rendered, acc, &[&1 | &2]))
  end

  defp assert_progress!(lines, rest) when length(rest) < length(lines), do: :ok

  defp assert_progress!(lines, _rest) do
    raise "telegram markdown block pass made no progress at: #{inspect(hd(lines))}"
  end

  defp take_block(["" | rest]), do: {[""], rest}

  defp take_block([line | rest] = lines) do
    cond do
      fence_lang(line) != nil -> take_fence(lines)
      quote_line?(line) -> take_quote(lines)
      table_start?(line, rest) -> take_table(lines)
      heading_content(line) != nil -> {[render_heading(line)], rest}
      bullet_line?(line) -> {[render_bullet(line)], rest}
      true -> take_paragraph(lines)
    end
  end

  defp take_fence([open | rest]) do
    lang = fence_lang(open)
    {body, _close, tail} = take_fence_body(rest, [])
    {[render_code_block(lang, body)], tail}
  end

  defp take_fence_body([], acc), do: {Enum.reverse(acc), nil, []}

  defp take_fence_body([line | rest], acc) do
    if fence_lang(line) == "" do
      {Enum.reverse(acc), line, rest}
    else
      take_fence_body(rest, [line | acc])
    end
  end

  defp render_code_block(lang, body_lines) do
    body = body_lines |> Enum.join("\n") |> trim_trailing_newline() |> escape()

    case String.trim(lang) do
      "" -> "<pre><code>" <> body <> "</code></pre>"
      lang -> ~s(<pre><code class="language-#{escape(lang)}">#{body}</code></pre>)
    end
  end

  defp take_quote(lines) do
    {quoted, tail} = Enum.split_while(lines, &quote_line?/1)
    inner_lines = Enum.map(quoted, &quote_content/1)
    inner = inner_lines |> Enum.join("\n") |> inline(@root_inline)
    {["<blockquote#{quote_modifier(inner_lines, inner)}>#{inner}</blockquote>"], tail}
  end

  defp quote_modifier(inner_lines, inner) do
    long? =
      length(inner_lines) > @quote_expandable_lines or
        String.length(plain_text(inner)) > @quote_expandable_chars

    if long?, do: " expandable", else: ""
  end

  defp quote_content(line) do
    [_, content] = Regex.run(@quote_pattern, line)
    content
  end

  defp take_table([header, _separator | rest]) do
    {body, tail} = Enum.split_while(rest, &table_row?/1)
    rows = Enum.map([header | body], &table_cells/1)
    {[render_table(rows)], tail}
  end

  defp table_cells(row) do
    row
    |> String.trim()
    |> String.trim("|")
    |> String.split("|")
    |> Enum.map(&(&1 |> String.trim() |> inline(@root_inline) |> plain_text()))
  end

  defp render_table(rows) do
    widths = table_widths(rows)
    [header | body] = Enum.map(rows, &render_table_row(&1, widths))
    rule = Enum.map_join(widths, "-+-", &String.duplicate("-", &1))
    "<pre>" <> Enum.join([header, rule | body], "\n") <> "</pre>"
  end

  defp table_widths(rows) do
    columns = rows |> Enum.map(&length/1) |> Enum.max()

    Enum.map(0..(columns - 1), fn index ->
      rows
      |> Enum.map(&(&1 |> Enum.at(index, "") |> String.length()))
      |> Enum.max()
    end)
  end

  defp render_table_row(cells, widths) do
    widths
    |> Enum.with_index()
    |> Enum.map_join(" | ", fn {width, index} ->
      cells |> Enum.at(index, "") |> String.pad_trailing(width)
    end)
    |> escape()
  end

  defp render_heading(line) do
    content =
      line
      |> heading_content()
      |> String.replace(@heading_bold_pattern, "\\1")
      |> inline(@root_inline)

    "<b>" <> content <> "</b>"
  end

  defp render_bullet(line) do
    [_, indent, content] = Regex.run(@bullet_pattern, line)
    indent <> "• " <> inline(content, @root_inline)
  end

  defp take_paragraph([first | rest]) do
    {more, tail} = take_paragraph_tail(rest, [])
    {[[first | more] |> Enum.join("\n") |> inline(@root_inline)], tail}
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
    line == "" or Regex.match?(@hr_pattern, line) or fence_lang(line) != nil or
      quote_line?(line) or table_start?(line, rest) or heading_content(line) != nil or
      bullet_line?(line)
  end

  defp drop_leading_blanks([]), do: []
  defp drop_leading_blanks(["" | rest]), do: drop_leading_blanks(rest)
  defp drop_leading_blanks(lines), do: lines

  defp ensure_blank_separator([]), do: []
  defp ensure_blank_separator(["" | _] = acc), do: acc
  defp ensure_blank_separator(acc), do: ["" | acc]

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

  defp table_start?(line, [next | _]) do
    table_row?(line) and separator_row?(next)
  end

  defp table_start?(_line, []), do: false

  defp separator_row?(line) do
    String.contains?(line, "|") and String.contains?(line, "-") and
      Regex.match?(@separator_row_pattern, line)
  end

  # -- Inline pass --

  defp inline(text, %{depth: depth}) when depth >= @max_inline_depth, do: escape(text)

  # The closer index covers exactly the text this pass walks, so a nested pass
  # over an inner substring builds its own rather than inheriting this one.
  defp inline(text, ctx) do
    scan(text, nil, [], Map.put(ctx, :scan, CloserScan.index(text, ctx.links)))
  end

  defp scan("", _prev, acc, _ctx), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp scan(text, prev, acc, ctx) do
    case take_construct(text, prev, ctx) do
      {:ok, html, rest, next_prev} ->
        assert_inline_progress!(text, rest)
        scan(rest, next_prev, [html | acc], ctx)

      :none ->
        <<char::utf8, rest::binary>> = text
        scan(rest, <<char::utf8>>, [escape_char(char) | acc], ctx)
    end
  end

  defp assert_inline_progress!(text, rest) when byte_size(rest) < byte_size(text), do: :ok

  defp assert_inline_progress!(text, _rest) do
    raise "telegram markdown inline pass made no progress at: #{inspect(text)}"
  end

  defp take_construct("`" <> rest, _prev, _ctx), do: code_span(rest)
  defp take_construct("[" <> rest, _prev, %{links: true} = ctx), do: link(rest, ctx)
  defp take_construct("**" <> rest, prev, ctx), do: emphasis(rest, "**", "b", prev, ctx)
  defp take_construct("~~" <> rest, prev, ctx), do: emphasis(rest, "~~", "s", prev, ctx)
  defp take_construct("*" <> rest, prev, ctx), do: emphasis(rest, "*", "i", prev, ctx)
  defp take_construct("_" <> rest, prev, ctx), do: emphasis(rest, "_", "i", prev, ctx)
  defp take_construct(_text, _prev, _ctx), do: :none

  defp code_span(text) do
    case :binary.split(text, "`") do
      [inner, rest] when inner != "" -> {:ok, "<code>#{escape(inner)}</code>", rest, "`"}
      _ -> :none
    end
  end

  defp link(text, ctx) do
    with [label, "(" <> target] <- :binary.split(text, "]"),
         {:ok, url, rest} <- split_url(target, "", 0),
         true <- CloserScan.link_parts?(label, url) do
      inner = inline(label, %{links: false, depth: ctx.depth + 1})
      {:ok, ~s(<a href="#{escape(url)}">#{inner}</a>), rest, ")"}
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

  defp emphasis(text, marker, tag, prev, ctx) do
    if opener?(text, prev) do
      close_emphasis(text, marker, tag, ctx)
    else
      :none
    end
  end

  defp close_emphasis(text, marker, tag, ctx) do
    case CloserScan.find(ctx.scan, text, marker) do
      {:ok, inner, rest} ->
        rendered = inline(inner, %{ctx | depth: ctx.depth + 1})
        {:ok, "<#{tag}>#{rendered}</#{tag}>", rest, marker}

      :none ->
        :none
    end
  end

  defp opener?(text, prev), do: not whitespace_start?(text) and not alnum?(prev)

  # -- Text helpers --

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape_char(?&), do: "&amp;"
  defp escape_char(?<), do: "&lt;"
  defp escape_char(?>), do: "&gt;"
  defp escape_char(?"), do: "&quot;"
  defp escape_char(char), do: <<char::utf8>>

  defp plain_text(html) do
    @tag_pattern
    |> Regex.replace(html, "")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&amp;", "&")
  end

  defp utf16_units(text) do
    case :unicode.characters_to_binary(text, :utf8, :utf16) do
      units when is_binary(units) -> div(byte_size(units), 2)
      other -> raise ArgumentError, "text is not valid UTF-8: #{inspect(other)}"
    end
  end

  defp normalize_newlines(text), do: String.replace(text, "\r\n", "\n")

  defp trim_trailing_newline(body) do
    if String.ends_with?(body, "\n"), do: binary_part(body, 0, byte_size(body) - 1), else: body
  end

  defp alnum?(nil), do: false
  defp alnum?(char), do: Regex.match?(@alnum_pattern, char)

  defp whitespace_start?(<<char::utf8, _::binary>>), do: char in [?\s, ?\t, ?\n, ?\r]
  defp whitespace_start?(_text), do: true

  # -- Oversized fence extraction --

  defp extract_fences([], _max, lines, blocks), do: {Enum.reverse(lines), blocks}

  defp extract_fences([line | rest] = lines, max, kept, blocks) do
    case fence_lang(line) do
      nil -> extract_fences(rest, max, [line | kept], blocks)
      lang -> extract_fence(lines, lang, max, kept, blocks)
    end
  end

  defp extract_fence([open | rest], lang, max, kept, blocks) do
    {body, close, tail} = take_fence_body(rest, [])
    source = Enum.join([open | body] ++ List.wrap(close), "\n")

    if rendered_utf16_length(source) > max do
      block = %{lang: blank_to_nil(lang), body: Enum.join(body, "\n")}
      extract_fences(tail, max, [@code_placeholder | kept], [block | blocks])
    else
      extract_fences(tail, max, Enum.reverse([open | body] ++ List.wrap(close)) ++ kept, blocks)
    end
  end

  defp blank_to_nil(lang) do
    case String.trim(lang) do
      "" -> nil
      lang -> lang
    end
  end
end
