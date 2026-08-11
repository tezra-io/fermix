defmodule FermixChannels.Outbound.Splitter do
  @moduledoc """
  Channel-agnostic splitter for long outbound text.

  Pure functions. No channel knowledge, no config, no I/O. Callers supply the
  limit and the measurer for their wire (graphemes, bytes, UTF-16 code units,
  ...), so one ladder serves every channel.

  Each chunk is filled toward `:limit` and cut at the highest-ranked boundary
  whose chunk still fits:

    1. section boundary — a blank line immediately before a markdown heading
       line (`#` .. `######` followed by a space); the *last* one that fits;
    2. paragraph boundary — a blank line;
    3. single newline;
    4. sentence end — `.`, `!` or `?` followed by a space or end of line;
    5. any whitespace;
    6. hard cut at the limit (grapheme-safe, last resort).

  Invariants, enforced by construction:

    * a cut never lands inside a fenced code block (``` parity) — the cut backs
      off to a boundary before the fence opens;
    * a chunk never ends with a heading line or with a line ending in `:` — the
      cut backs off so the heading / lead-in opens the next chunk. This governs
      split-induced cuts only: a text whose genuine last line is a heading keeps
      it, because the final chunk is emitted whole rather than cut;
    * trailing horizontal-rule lines (`---`, `***`, `___` alone on a line) and
      trailing blank lines are stripped from each chunk; chunks are trimmed of
      surrounding whitespace and otherwise verbatim;
    * with `:entity_count` given, every chunk also satisfies
      `entity_count.(chunk) <= entity_budget` — an over-budget cut backs off
      along the same ladder;
    * every emitted chunk consumes at least one grapheme; non-progress raises
      rather than looping;
    * empty or whitespace-only input returns `[]`.

  ## Oversized atomic blocks are the caller's policy

  A fenced code block that alone exceeds `:limit` cannot be split without
  corrupting both halves, so it is emitted as its own chunk **unchanged** — that
  chunk may exceed `:limit`. Owning what happens to it is the caller's job:
  Telegram pre-extracts such a block into a `sendDocument` attachment, while
  plain channels let the platform reject that single send loudly. This module
  never silently mutates or drops it.

  `:measure` and `:entity_count` are assumed monotonic over prefixes (a longer
  prefix never measures smaller) — true of every length or entity counter — so
  the fitting boundary can be found by binary search.
  """

  @type measure :: (String.t() -> non_neg_integer())

  @typep ctx :: %{
           limit: pos_integer(),
           measure: measure(),
           entity_count: measure() | nil,
           entity_budget: pos_integer()
         }

  @default_entity_budget 90

  @heading_re ~r/^\#{1,6} /
  @rule_re ~r/^(-{3,}|\*{3,}|_{3,})$/
  @sentence_re ~r/[.!?](?=[ \n])/
  @whitespace_re ~r/\s+/u

  @doc """
  Splits `text` into chunks that each fit `:limit` as reported by `:measure`.

  Options:

    * `:limit` — positive integer, required; raises `ArgumentError` otherwise.
    * `:measure` — `t:measure/0`, defaults to `&String.length/1`. Applied to the
      raw chunk text.
    * `:entity_count` — `t:measure/0` or `nil` (default): a second, independent
      fill condition (e.g. Telegram formatting entities).
    * `:entity_budget` — positive integer, default #{@default_entity_budget};
      only consulted when `:entity_count` is given.
  """
  @spec split(String.t(), keyword()) :: [String.t()]
  def split(text, opts) when is_binary(text) and is_list(opts) do
    ctx = build_ctx(opts)
    trimmed = String.trim(text)

    case trimmed do
      "" -> []
      _ -> do_split(trimmed, ctx, [])
    end
  end

  @doc """
  Streaming rotation primitive: the FIRST chunk of `text` plus the byte offset a
  caller advances by (CHANNEL_LONGFORM_PRESENTATION §6).

  Returns `:fits` when the whole text measures within `:limit` — there is nothing
  to rotate yet. Otherwise returns `{:chunk, chunk, consumed}` where `chunk` is
  exactly what `split/2` would emit first (same ladder, same invariants) and
  `consumed` is the number of **raw bytes of the given text** the chunk covers,
  *including* the whitespace and blank lines trimmed off both of its edges. So
  `binary_part(text, consumed, byte_size(text) - consumed)` is the remainder to
  keep streaming, always starting on a grapheme boundary, and
  `finalize(binary_part(text, 0, consumed)) == chunk`.

  Takes the same options as `split/2`.
  """
  @spec first_chunk(String.t(), keyword()) ::
          {:chunk, String.t(), consumed_bytes :: pos_integer()} | :fits
  def first_chunk(text, opts) when is_binary(text) and is_list(opts) do
    ctx = build_ctx(opts)
    trimmed = String.trim(text)
    lead = byte_size(text) - byte_size(String.trim_leading(text))

    if trimmed == "" or fits?(trimmed, ctx) do
      :fits
    else
      take_first(trimmed, lead, ctx)
    end
  end

  # --- option validation -----------------------------------------------------

  @spec build_ctx(keyword()) :: ctx()
  defp build_ctx(opts) do
    %{
      limit: validate_pos_integer!(Keyword.get(opts, :limit), :limit),
      measure: validate_measure!(Keyword.get(opts, :measure, &String.length/1), :measure),
      entity_count: validate_entity_count!(Keyword.get(opts, :entity_count)),
      entity_budget:
        validate_pos_integer!(
          Keyword.get(opts, :entity_budget, @default_entity_budget),
          :entity_budget
        )
    }
  end

  defp validate_pos_integer!(value, _key) when is_integer(value) and value > 0, do: value

  defp validate_pos_integer!(value, key) do
    raise ArgumentError,
          "#{inspect(key)} must be a positive integer, got: #{inspect(value)}"
  end

  defp validate_measure!(fun, _key) when is_function(fun, 1), do: fun

  defp validate_measure!(value, key) do
    raise ArgumentError,
          "#{inspect(key)} must be a 1-arity function, got: #{inspect(value)}"
  end

  defp validate_entity_count!(nil), do: nil
  defp validate_entity_count!(fun), do: validate_measure!(fun, :entity_count)

  # --- recursion -------------------------------------------------------------

  @spec do_split(String.t(), ctx(), [String.t()]) :: [String.t()]
  defp do_split("", _ctx, acc), do: Enum.reverse(acc)

  defp do_split(text, ctx, acc) do
    case cut_point(text, ctx) do
      :fits ->
        Enum.reverse(prepend(finalize(text), acc))

      {:cut, offset, mode} ->
        {chunk, rest} = emit_at(text, offset, mode)
        assert_progress!(text, rest)
        do_split(rest, ctx, prepend(chunk, acc))
    end
  end

  # Walks forward past chunks that finalize to nothing (a lead of blank or rule
  # lines only) so the answer is always a chunk a caller can show. Bounded by
  # `assert_progress!`: every step is strictly shorter than the last.
  @spec take_first(String.t(), non_neg_integer(), ctx()) :: {:chunk, String.t(), pos_integer()}
  defp take_first(text, consumed, ctx) do
    case cut_point(text, ctx) do
      :fits -> {:chunk, finalize(text), consumed + byte_size(text)}
      {:cut, offset, mode} -> advance_first(text, consumed, ctx, offset, mode)
    end
  end

  defp advance_first(text, consumed, ctx, offset, mode) do
    {chunk, rest} = emit_at(text, offset, mode)
    assert_progress!(text, rest)
    consumed = consumed + byte_size(text) - byte_size(rest)

    case chunk do
      "" -> take_first(rest, consumed, ctx)
      _ -> {:chunk, chunk, consumed}
    end
  end

  defp prepend("", acc), do: acc
  defp prepend(chunk, acc), do: [chunk | acc]

  defp assert_progress!(text, rest) do
    if byte_size(rest) >= byte_size(text) do
      raise RuntimeError,
            "splitter made no progress on a #{byte_size(text)}-byte chunk; refusing to loop"
    end

    :ok
  end

  # --- one chunk -------------------------------------------------------------

  # The single source of boundary truth: where the first chunk of `text` ends,
  # and how that chunk is rendered. `split/2` recurses on it; `first_chunk/2`
  # calls it once.
  @spec cut_point(String.t(), ctx()) :: :fits | {:cut, pos_integer(), :verbatim | :finalize}
  defp cut_point(text, ctx) do
    if fits?(text, ctx) do
      :fits
    else
      cut_point_of(text, ctx)
    end
  end

  defp cut_point_of(text, ctx) do
    lines = lines_with_offsets(text)
    ranges = fence_ranges(lines, byte_size(text))

    case atomic_lead(text, ranges, ctx) do
      {:ok, offset} -> {:cut, offset, :verbatim}
      :none -> {:cut, cut_offset(text, ctx, lines, ranges), :finalize}
    end
  end

  defp emit_at(text, offset, mode) do
    head = binary_part(text, 0, offset)
    tail = binary_part(text, offset, byte_size(text) - offset)
    {render_chunk(head, mode), String.trim_leading(tail)}
  end

  defp render_chunk(head, :verbatim), do: String.trim(head)
  defp render_chunk(head, :finalize), do: finalize(head)

  # A fenced block opening at offset 0 that does not fit on its own is atomic.
  defp atomic_lead(text, [{0, fence_end} | _rest], ctx) do
    if fits?(binary_part(text, 0, fence_end), ctx), do: :none, else: {:ok, fence_end}
  end

  defp atomic_lead(_text, _ranges, _ctx), do: :none

  @spec cut_offset(String.t(), ctx(), [{String.t(), non_neg_integer()}], [
          {non_neg_integer(), non_neg_integer()}
        ]) :: pos_integer()
  defp cut_offset(text, ctx, lines, ranges) do
    offset =
      ladder_offset(text, ctx, lines, ranges) || hard_cut_offset(text, ctx, ranges)

    if offset <= 0 do
      raise RuntimeError,
            ":limit #{ctx.limit} admits no cut of the remaining text; a chunk must consume " <>
              "at least one grapheme"
    end

    offset
  end

  defp ladder_offset(text, ctx, lines, ranges) do
    Enum.find_value(
      [
        fn -> section_candidates(lines, ranges) end,
        fn -> paragraph_candidates(lines, ranges) end,
        fn -> line_candidates(lines, ranges) end,
        fn -> sentence_candidates(text, ranges) end,
        fn -> whitespace_candidates(text, ranges) end
      ],
      fn build -> best_candidate(build.(), text, ctx) end
    )
  end

  # --- candidate ladder ------------------------------------------------------

  defp section_candidates(lines, ranges) do
    lines
    |> Enum.zip(Enum.drop(lines, 1))
    |> Enum.filter(fn {{blank, _off}, {next, _next_off}} ->
      blank?(blank) and heading?(next)
    end)
    |> Enum.map(fn {{_blank, off}, _next} -> off end)
    |> usable(ranges)
  end

  defp paragraph_candidates(lines, ranges) do
    lines
    |> Enum.filter(fn {line, _off} -> blank?(line) end)
    |> Enum.map(fn {_line, off} -> off end)
    |> usable(ranges)
  end

  defp line_candidates(lines, ranges) do
    lines
    |> Enum.map(fn {_line, off} -> off end)
    |> usable(ranges)
  end

  defp sentence_candidates(text, ranges) do
    @sentence_re
    |> Regex.scan(text, return: :index)
    |> Enum.map(fn [{pos, len} | _] -> pos + len end)
    |> usable(ranges)
  end

  defp whitespace_candidates(text, ranges) do
    @whitespace_re
    |> Regex.scan(text, return: :index)
    |> Enum.map(fn [{pos, len} | _] -> pos + len end)
    |> usable(ranges)
  end

  defp usable(offsets, ranges) do
    Enum.filter(offsets, fn off -> off > 0 and outside_fence?(off, ranges) end)
  end

  # Ascending offsets; returns the largest one that fits and leaves no orphan.
  defp best_candidate([], _text, _ctx), do: nil

  defp best_candidate(candidates, text, ctx) do
    arr = List.to_tuple(candidates)
    last = last_fitting(arr, 0, tuple_size(arr) - 1, -1, text, ctx)
    acceptable_at(arr, last, text)
  end

  defp last_fitting(arr, lo, hi, best, text, ctx) when lo <= hi do
    mid = div(lo + hi, 2)

    case fits?(binary_part(text, 0, elem(arr, mid)), ctx) do
      true -> last_fitting(arr, mid + 1, hi, mid, text, ctx)
      false -> last_fitting(arr, lo, mid - 1, best, text, ctx)
    end
  end

  defp last_fitting(_arr, _lo, _hi, best, _text, _ctx), do: best

  defp acceptable_at(_arr, index, _text) when index < 0, do: nil

  defp acceptable_at(arr, index, text) do
    offset = elem(arr, index)

    case orphan_tail?(binary_part(text, 0, offset)) do
      true -> acceptable_at(arr, index - 1, text)
      false -> offset
    end
  end

  # Last resort: the longest grapheme prefix that fits, pulled back out of any
  # fence it would land inside.
  defp hard_cut_offset(text, ctx, ranges) do
    graphemes = String.length(text)
    count = last_fitting_length(text, ctx, 1, graphemes, 0)
    offset = byte_size(String.slice(text, 0, count))

    case containing_fence(offset, ranges) do
      nil -> offset
      {start, _fence_end} -> start
    end
  end

  defp last_fitting_length(text, ctx, lo, hi, best) when lo <= hi do
    mid = div(lo + hi, 2)

    case fits?(String.slice(text, 0, mid), ctx) do
      true -> last_fitting_length(text, ctx, mid + 1, hi, mid)
      false -> last_fitting_length(text, ctx, lo, mid - 1, best)
    end
  end

  defp last_fitting_length(_text, _ctx, _lo, _hi, best), do: best

  # --- measurement -----------------------------------------------------------

  defp fits?(text, ctx) do
    ctx.measure.(text) <= ctx.limit and entities_fit?(text, ctx)
  end

  defp entities_fit?(_text, %{entity_count: nil}), do: true
  defp entities_fit?(text, ctx), do: ctx.entity_count.(text) <= ctx.entity_budget

  # --- chunk shaping ---------------------------------------------------------

  defp finalize(chunk) do
    chunk
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.drop_while(fn line -> blank?(line) or rule?(line) end)
    |> Enum.reverse()
    |> Enum.join("\n")
    |> String.trim()
  end

  defp orphan_tail?(chunk) do
    case chunk |> finalize() |> String.split("\n") |> List.last() do
      nil -> false
      line -> heading?(line) or String.ends_with?(line, ":")
    end
  end

  # --- line / fence geometry -------------------------------------------------

  defp lines_with_offsets(text) do
    text
    |> String.split("\n")
    |> Enum.map_reduce(0, fn line, off -> {{line, off}, off + byte_size(line) + 1} end)
    |> elem(0)
  end

  defp fence_ranges(lines, text_size) do
    {ranges, open} = Enum.reduce(lines, {[], nil}, &toggle_fence(&1, &2, text_size))

    ranges
    |> close_dangling(open, text_size)
    |> Enum.reverse()
  end

  defp toggle_fence({line, off}, {ranges, open}, text_size) do
    cond do
      not fence_line?(line) -> {ranges, open}
      is_nil(open) -> {ranges, off}
      true -> {[{open, min(off + byte_size(line) + 1, text_size)} | ranges], nil}
    end
  end

  defp close_dangling(ranges, nil, _text_size), do: ranges
  defp close_dangling(ranges, open, text_size), do: [{open, text_size} | ranges]

  defp outside_fence?(offset, ranges) do
    is_nil(containing_fence(offset, ranges))
  end

  defp containing_fence(offset, ranges) do
    Enum.find(ranges, fn {start, fence_end} -> offset > start and offset < fence_end end)
  end

  # --- line predicates -------------------------------------------------------

  defp blank?(line), do: String.trim(line) == ""

  defp heading?(line), do: Regex.match?(@heading_re, line)

  defp rule?(line), do: Regex.match?(@rule_re, String.trim(line))

  defp fence_line?(line), do: line |> String.trim_leading() |> String.starts_with?("```")
end
