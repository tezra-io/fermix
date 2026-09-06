defmodule FermixChannels.Outbound.CloserScan do
  @moduledoc """
  Finds the closing delimiter of an emphasis run, indexed once per inline pass.

  Both outbound Markdown renderers hunt closers by exactly the same rules —
  `FermixChannels.Channels.Telegram.Markdown` and `FermixChannels.Outbound.Dialect`
  differ in what they *emit*, not in what they parse — so the search lives here
  once rather than as two copies free to drift apart.

  The rules are unchanged. Hunting a closer steps *over* the constructs nested
  inside the run rather than into them, so an inner construct is never torn in
  half:

    * a code span (`` `…` ``) and a link (`[…](…)`) are skipped whole — a
      delimiter inside either one is not a closer, exactly as the opener-side
      parser already treats them as atomic;
    * a run of two or more identical delimiters belongs to the doubled marker
      (`**` bold, `~~` strikethrough), so it never closes a single-character
      italic — `*a **b** c*` emphasises `a **b** c` as one span, and the scan
      resumes past the whole run;
    * a closer needs a non-empty body, sits immediately after non-whitespace,
      and is not followed by an alphanumeric.

  ## Why the search is indexed rather than walked

  One scan is linear, but an *unmatched* opener walks the entire remaining text
  before giving up, so a paragraph of stray delimiters — `**a **a **a …`, which
  models emit whenever they mean literal asterisks — paid one full walk per
  opener and rendering went quadratic: 4 kB took 119 ms, 32 kB took 10.8 s. That
  is on the delivery path of every message and inside the outbound splitter's
  binary search, which re-measures the same text repeatedly. This is the second
  round of that lesson: the walk itself replaced a scan that rebuilt the inner
  text one codepoint at a time and called `String.last/1` on it at every step,
  which was *cubic* and took ~25 s on the same 4 kB. Every test below therefore
  reads bytes in place — at most four of them, and a delimiter is always ASCII,
  so a candidate offset is always a codepoint boundary.

  Every decision the walk makes about a candidate byte is *position-local*: it
  reads the bytes around that candidate and nothing about where the scan began.
  The single exception is the non-empty-body rule, which is relative to the
  scan's own start. So `index/2` classifies every candidate in the text exactly
  once, right to left, recording where a scan that reaches that candidate ends
  up; `find/3` then answers a whole scan with one binary search. The exception
  is carried as a second field per candidate — where the scan resumes when that
  candidate cannot close — which is precisely what a scan starting *on* a
  candidate needs, so the start rule costs a table read rather than a re-walk.
  Rendering is O(n log n) in the text size.

  Run lengths are folded through the same right-to-left pass instead of being
  measured per candidate: measuring is O(1) amortised on `**a **a …` but O(n)
  on a long `****…` divider, which the old walk never paid because it left the
  run in one step and this one classifies every position inside it.

  Pure, and holds nothing between calls: the index is built at inline-pass entry
  and handed back for the caller to thread through its own context, so a nested
  pass over an inner substring indexes that substring and no state is shared.
  """

  # The markers both renderers' `take_construct/3` clauses recognise. One added
  # there but not here fails loudly on its first scan, in `find/3`'s `fetch!`,
  # rather than silently rendering by different rules.
  @markers ["**", "~~", "*", "_"]

  @alnum_pattern ~r/^[\p{L}\p{N}]$/u

  @typedoc """
  Where a scan that reaches this candidate ends up, and where it resumes
  instead when the candidate cannot close the run.
  """
  @type entry :: {non_neg_integer() | :none, non_neg_integer()}

  @typedoc "Candidate byte offsets in ascending order, and their entries."
  @type table :: {tuple(), %{optional(non_neg_integer()) => entry()}}

  @typedoc "One inline pass's index over one text."
  @type t :: %{root_size: non_neg_integer(), tables: %{optional(binary()) => table()}}

  @doc """
  Indexes `text` for every closer search the inline pass over it will run.

  `links?` mirrors the pass's own context: a link label is parsed with links
  off, and there a `[` is not a construct to step over.
  """
  @spec index(binary(), boolean()) :: t()
  def index(text, links?) when is_binary(text) and is_boolean(links?) do
    tables =
      @markers
      |> Enum.filter(&String.contains?(text, &1))
      |> Map.new(&{&1, build(text, &1, links?)})

    %{root_size: byte_size(text), tables: tables}
  end

  @doc """
  Finds the closer of a run opened immediately before `text`.

  `text` is the remainder of the indexed text — everything after the opening
  marker — and the answer is that run's inner text plus what follows the closer.
  """
  @spec find(t(), binary(), binary()) :: {:ok, binary(), binary()} | :none
  def find(%{root_size: root_size, tables: tables}, text, marker)
      when is_binary(text) and is_binary(marker) do
    start = start_offset!(root_size, text)
    {positions, entries} = Map.fetch!(tables, marker)

    positions
    |> first_at_or_after(start)
    |> resolve(positions, entries, start)
    |> deliver(text, marker, start)
  end

  @doc """
  True when `label` and `url` are the halves of a link this parser admits.

  Shared with both renderers so that measuring a link to step over it and
  rendering one can never disagree about what a link is.
  """
  @spec link_parts?(binary(), binary()) :: boolean()
  def link_parts?(label, url) when is_binary(label) and is_binary(url) do
    label != "" and url != "" and not String.contains?(label, "\n") and
      not Regex.match?(~r/\s/u, url)
  end

  # -- Query --

  # `text` is a suffix of the indexed text, so its length names its offset.
  defp start_offset!(root_size, text) when byte_size(text) <= root_size do
    root_size - byte_size(text)
  end

  defp start_offset!(root_size, text) do
    raise "closer scan text of #{byte_size(text)} bytes is not a suffix of a #{root_size}-byte root"
  end

  # A candidate sitting on the scan's own start cannot close it — the body would
  # be empty — so the scan resumes where that candidate skips to, and every
  # candidate past that point is far enough along for the table to hold.
  defp resolve(:none, _positions, _entries, _start), do: :none

  defp resolve(start, positions, entries, start) do
    {_outcome, skip} = Map.fetch!(entries, start)

    case first_at_or_after(positions, skip) do
      :none -> :none
      at -> outcome(entries, at)
    end
  end

  defp resolve(at, _positions, entries, _start), do: outcome(entries, at)

  defp outcome(entries, at) do
    {outcome, _skip} = Map.fetch!(entries, at)
    outcome
  end

  defp deliver(:none, _text, _marker, _start), do: :none

  defp deliver(at, text, marker, start) do
    closer = at - start
    {:ok, binary_part(text, 0, closer), tail_after(text, closer, marker)}
  end

  # -- Index build --

  defp build(root, marker, links?) do
    positions =
      root
      |> :binary.matches(candidate_bytes(marker, links?))
      |> Enum.map(&elem(&1, 0))

    ordered = List.to_tuple(positions)

    {entries, _at, _run} =
      Enum.reduce(Enum.reverse(positions), {%{}, -1, 0}, fn at, acc ->
        record(root, marker, ordered, at, acc)
      end)

    {ordered, entries}
  end

  # The only bytes that can close the run or open a construct to step over.
  defp candidate_bytes(marker, true), do: [<<marker_byte(marker)>>, "`", "["]
  defp candidate_bytes(marker, false), do: [<<marker_byte(marker)>>, "`"]

  # Right to left, so the candidate a skip lands on is already recorded, and so
  # the run length one place to the right is one addition away.
  defp record(root, marker, ordered, at, {entries, next_at, next_run}) do
    run = marker_run(root, at, marker_byte(marker), next_at, next_run)
    {closer?, skip} = classify(root, at, marker, run)
    advanced!(at, skip)
    entry = {chase(closer?, at, ordered, entries, skip), skip}
    {Map.put(entries, at, entry), at, run}
  end

  defp chase(true, at, _ordered, _entries, _skip), do: at

  defp chase(false, _at, ordered, entries, skip) do
    case first_at_or_after(ordered, skip) do
      :none -> :none
      at -> outcome(entries, at)
    end
  end

  # Length of the run of marker bytes starting at `at`, and 0 when `at` holds
  # some other candidate. Every marker byte is itself a candidate, so the run at
  # `at + 1` is already known whenever it is part of this one.
  defp marker_run(root, at, byte, next_at, next_run) do
    cond do
      :binary.at(root, at) != byte -> 0
      next_at == at + 1 -> next_run + 1
      true -> 1
    end
  end

  # `closer?` is what the scan decides when the candidate may close the run;
  # `skip` is where it resumes when it may not. Both read only the bytes around
  # `at`, which is what lets the whole table be precomputed.
  defp classify(root, at, marker, run) do
    case :binary.at(root, at) do
      ?` -> {false, skip_to(code_span_end(root, at), at)}
      ?[ -> {false, skip_to(link_end(root, at), at)}
      _delimiter -> delimiter_candidate(root, at, marker, run)
    end
  end

  defp skip_to({:ok, next}, _at), do: next
  defp skip_to(:none, at), do: at + 1

  defp delimiter_candidate(text, at, marker, run) do
    cond do
      run < byte_size(marker) -> {false, at + 1}
      inner_run?(run, marker) -> {false, at + run}
      closer?(text, at, marker) -> {true, at + 1}
      true -> {false, at + 1}
    end
  end

  defp advanced!(at, next) when next > at, do: :ok

  defp advanced!(at, next) do
    raise "closer scan made no progress at byte #{at} (next: #{next})"
  end

  # -- Candidate tests --

  # A doubled delimiter belongs to the bold/strikethrough construct nested
  # inside, so it can never close a single-character italic.
  defp inner_run?(run, marker), do: run > 1 and byte_size(marker) == 1

  # Flanking: a closer sits immediately after non-whitespace and is not followed
  # by an alphanumeric. The non-empty-body half of the rule is relative to the
  # scan's start rather than to the text, so `find/3` applies it — see
  # `resolve/4`. Offset 0 has no preceding byte at all, and only a scan starting
  # there can reach it, which is that same case.
  defp closer?(_text, 0, _marker), do: false

  defp closer?(text, at, marker) do
    not whitespace_byte?(:binary.at(text, at - 1)) and
      not alnum_start?(next_char(text, at, marker))
  end

  # `code_span/1` accepts a body that is non-empty and ends at the next backtick.
  defp code_span_end(text, at) do
    case :binary.match(text, "`", scope: {at + 1, byte_size(text) - at - 1}) do
      {close, 1} when close > at + 1 -> {:ok, close + 1}
      _other -> :none
    end
  end

  # `[label](url)` measured rather than rendered, admitting exactly what the
  # renderers' `link/2` admits: the first `]`, an immediate `(`, and a
  # balanced-paren target.
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

  # Byte just past the `)` closing a link target, parentheses balanced.
  defp url_end(text, at, _depth) when at >= byte_size(text), do: :none

  defp url_end(text, at, depth) do
    case {:binary.at(text, at), depth} do
      {?), 0} -> {:ok, at + 1}
      {?), _depth} -> url_end(text, at + 1, depth - 1)
      {?(, _depth} -> url_end(text, at + 1, depth + 1)
      {_byte, _depth} -> url_end(text, at + 1, depth)
    end
  end

  # -- Byte helpers --

  # Smallest candidate offset at or after `from`, halving the range each step.
  defp first_at_or_after(ordered, from), do: bisect(ordered, from, 0, tuple_size(ordered))

  defp bisect(ordered, _from, low, high) when low == high do
    if low < tuple_size(ordered), do: elem(ordered, low), else: :none
  end

  defp bisect(ordered, from, low, high) when low < high do
    middle = div(low + high, 2)

    if elem(ordered, middle) < from,
      do: bisect(ordered, from, middle + 1, high),
      else: bisect(ordered, from, low, middle)
  end

  defp marker_byte(marker), do: :binary.at(marker, 0)

  defp byte_at(text, at) when at < byte_size(text), do: :binary.at(text, at)
  defp byte_at(_text, _at), do: nil

  defp slice(text, from, to), do: binary_part(text, from, to - from)

  defp tail_after(text, at, marker) do
    from = at + byte_size(marker)
    binary_part(text, from, byte_size(text) - from)
  end

  # Four bytes always hold the whole next codepoint, so the alphanumeric test
  # never has to copy the tail.
  defp next_char(text, at, marker) do
    from = at + byte_size(marker)
    binary_part(text, from, min(4, byte_size(text) - from))
  end

  defp alnum_start?(<<char::utf8, _rest::binary>>),
    do: Regex.match?(@alnum_pattern, <<char::utf8>>)

  defp alnum_start?(_text), do: false

  # Safe on a raw byte: every whitespace it tests is ASCII, and a UTF-8
  # continuation byte can never equal one.
  defp whitespace_byte?(byte), do: byte in [?\s, ?\t, ?\n, ?\r]
end
