defmodule FermixCore.ComputerHistory.Summarizer.EventRender do
  @moduledoc """
  Renders a spool batch into the summarizer's user message (MILESTONE_32 §10).

  One line per event, in id order, in a fixed selected schema — every column the
  prompt asks the model to reason from (url, page title) plus the coverage
  markers that say what was NOT observed (`withheld`, `chars=`, `flag=`,
  `gap=`). Times are local to the operator's timezone, because the model is
  asked to describe an owner's day, not an epoch.

  Three reductions keep a 500-event batch inside a bounded prompt without
  dropping the evidence that matters:

    * **clipping** — a long value renders head + `[…N chars omitted…]` + tail, so
      the END of a long field (usually the point of it) survives;
    * **delta** — a field re-observed after growth renders only what changed,
      marked `text(unchanged first P chars)=`;
    * **dedupe** — an identical consecutive line is emitted once with ` ×N`.

  The batch is then cut to `@input_char_budget`: the events that fit ARE the
  batch, and the caller advances its cursor only past those — the rest wait for
  the next batch of the same cycle. A single line is bounded by the clip
  constants (asserted against the budget at compile time), so the first event of
  a batch always fits and the cursor can never stall on one oversized event.
  """

  alias FermixCore.ComputerHistory.Config

  # Clipping: keep the opening and the ending of a long value.
  @text_head 600
  @text_tail 300
  # Below this many unchanged leading characters a re-observation is rendered in
  # full — a short shared prefix says nothing about the edit.
  @delta_prefix_floor 200
  @input_char_budget 60_000
  # The header is written after the body is budgeted (its date range depends on
  # what was rendered), so the body reserves room for it. An IANA zone name is
  # far shorter than this.
  @header_reserve 128

  # The ten rendered values (type, app, window, page, host, url, field, text,
  # flag, gap reason), each clipped to head+tail plus a marker and at most
  # doubled by escaping, plus the fixed labels and coverage markers. The budget
  # MUST exceed this: an event that could never fit would stall the cursor on it
  # forever.
  @rendered_values 10
  @max_line_chars @rendered_values * 2 * (@text_head + @text_tail + 40) + 512

  if @input_char_budget <= @max_line_chars + @header_reserve do
    raise "computer_history input budget #{@input_char_budget} must exceed the " <>
            "per-line bound #{@max_line_chars} plus the header reserve #{@header_reserve}"
  end

  @doc "The default character cap on one rendered user message."
  @spec default_budget() :: pos_integer()
  def default_budget, do: @input_char_budget

  @doc """
  The upper bound on ONE rendered line. A caller that budgets a message below
  this cannot be sure any event fits, and an event that never fits stalls the
  cursor on it forever.
  """
  @spec max_line_chars() :: pos_integer()
  def max_line_chars, do: @max_line_chars

  @doc """
  Render `events` (id order) into `{user_message, rendered_events}`. `opts`:
  `:timezone` (defaults to the operator's), `:budget` (character cap on the
  rendered message). `rendered_events` is the prefix of `events` that fit — the
  caller's real batch.
  """
  @spec render([map()], keyword()) :: {String.t(), [map()]}
  def render(events, opts \\ []) when is_list(events) and is_list(opts) do
    tz = Config.timezone(opts)
    budget = Keyword.get(opts, :budget, @input_char_budget) - @header_reserve

    events
    |> Enum.reduce_while(new_accumulator(), &accumulate(&1, &2, tz, budget))
    |> finish(tz)
  end

  defp new_accumulator, do: %{lines: [], rendered: [], chars: 0, previous_text: %{}}

  defp accumulate(event, acc, tz, budget) do
    {body, previous_text} = body(event, acc.previous_text, tz)
    acc = %{acc | previous_text: previous_text}

    if repeat?(acc, body),
      do: repeat_line(acc, event, budget),
      else: append_line(acc, event, body, tz, budget)
  end

  # --- line accumulation --------------------------------------------------

  defp repeat?(%{lines: [%{body: previous} | _rest]}, body), do: previous == body
  defp repeat?(_acc, _body), do: false

  defp repeat_line(%{lines: [line | rest]} = acc, event, budget) do
    repeat = line.repeat + 1
    growth = repeat_chars(repeat) - repeat_chars(line.repeat)

    if acc.chars + growth > budget do
      {:halt, acc}
    else
      {:cont,
       %{
         acc
         | lines: [%{line | repeat: repeat} | rest],
           chars: acc.chars + growth,
           rendered: [event | acc.rendered]
       }}
    end
  end

  defp append_line(acc, event, body, tz, budget) do
    line = %{time: clock(event.ts, tz), body: body, repeat: 1}
    cost = String.length(line.time) + 1 + String.length(body) + newline_chars(acc)

    if acc.chars + cost > budget do
      {:halt, acc}
    else
      {:cont,
       %{
         acc
         | lines: [line | acc.lines],
           chars: acc.chars + cost,
           rendered: [event | acc.rendered]
       }}
    end
  end

  defp newline_chars(%{lines: []}), do: 0
  defp newline_chars(_acc), do: 1

  defp repeat_chars(1), do: 0
  defp repeat_chars(count), do: String.length(" ×#{count}")

  defp finish(%{rendered: []}, _tz), do: {"", []}

  defp finish(acc, tz) do
    rendered = Enum.reverse(acc.rendered)
    body = acc.lines |> Enum.reverse() |> Enum.map_join("\n", &line_text/1)
    {"#{header(rendered, tz)}\n#{body}", rendered}
  end

  defp line_text(%{repeat: 1} = line), do: "#{line.time} #{line.body}"
  defp line_text(line), do: "#{line.time} #{line.body} ×#{line.repeat}"

  # The span is over the batch's earliest and latest `ts`, not its first and last
  # id: a late-flushed event reaches back, and a header reading "Aug 16–Aug 15"
  # is not a date range.
  defp header(rendered, tz) do
    stamps = Enum.map(rendered, & &1.ts)
    from = stamps |> Enum.min() |> local(tz)
    to = stamps |> Enum.max() |> local(tz)
    "Activity events (#{date_range(from, to)}, times in #{tz}):"
  end

  defp date_range(from, to) do
    from_day = Calendar.strftime(from, "%b %-d")
    to_day = Calendar.strftime(to, "%b %-d")
    if from_day == to_day, do: from_day, else: "#{from_day}–#{to_day}"
  end

  # --- one event's body ---------------------------------------------------

  defp body(event, previous_text, tz) do
    {text_part, clipped?, previous_text} = text_part(event, previous_text)

    parts = [
      clipped_bare(event.type),
      labeled(event, :bundle_id, "app"),
      quoted(event, :window_title, "window"),
      quoted(event, :page_title, "page"),
      labeled(event, :host, "host"),
      quoted(event, :url, "url"),
      quoted(event, :field_label, "field"),
      text_part,
      withheld(event),
      char_len(event, clipped?),
      labeled(event, :scan_flag, "flag"),
      gap(event, tz)
    ]

    {parts |> Enum.reject(&is_nil/1) |> Enum.join(" "), previous_text}
  end

  # A re-observed field value renders as its delta: the model needs what changed,
  # not the unchanged 4 KB before it. Tracked per (app, field) within the batch,
  # and only for a LABELLED field — without a label two values from the same app
  # are two different fields, and calling the second an edit of the first would
  # invent an edit that never happened.
  defp text_part(%{type: "field.value", text: text, field_label: label} = event, previous_text)
       when is_binary(text) and text != "" and is_binary(label) and label != "" do
    key = {Map.get(event, :bundle_id), label}
    {part, clipped?} = delta_or_full(Map.get(previous_text, key), text)
    {part, clipped?, Map.put(previous_text, key, text)}
  end

  defp text_part(%{text: text}, previous_text) when is_binary(text) and text != "" do
    {part, clipped?} = full_text(text)
    {part, clipped?, previous_text}
  end

  defp text_part(_event, previous_text), do: {nil, false, previous_text}

  defp delta_or_full(previous, text) when is_binary(previous) do
    prefix_bytes = codepoint_boundary(text, :binary.longest_common_prefix([previous, text]))
    prefix_chars = String.length(binary_part(text, 0, prefix_bytes))
    remainder = binary_part(text, prefix_bytes, byte_size(text) - prefix_bytes)

    if remainder != "" and prefix_chars >= @delta_prefix_floor,
      do: delta_text(prefix_chars, remainder),
      else: full_text(text)
  end

  defp delta_or_full(_absent, text), do: full_text(text)

  defp full_text(text) do
    {clipped, clipped?} = clip(text)
    {"text=#{quote_value(clipped)}", clipped?}
  end

  defp delta_text(prefix_chars, remainder) do
    {clipped, clipped?} = clip(remainder)
    {"text(unchanged first #{prefix_chars} chars)=#{quote_value(clipped)}", clipped?}
  end

  defp clip(value) do
    length = String.length(value)

    if length <= @text_head + @text_tail do
      {value, false}
    else
      head = String.slice(value, 0, @text_head)
      tail = String.slice(value, length - @text_tail, @text_tail)
      {"#{head} […#{length - @text_head - @text_tail} chars omitted…] #{tail}", true}
    end
  end

  # --- coverage markers ---------------------------------------------------

  defp withheld(%{content_withheld: flag}) when flag in [1, true], do: "withheld"
  defp withheld(_event), do: nil

  # The character count is evidence only where the text itself is missing or cut.
  defp char_len(%{char_len: count} = event, clipped?) when is_integer(count) do
    if blank?(Map.get(event, :text)) or clipped?, do: "chars=#{count}", else: nil
  end

  defp char_len(_event, _clipped?), do: nil

  defp gap(%{type: "observer.gap"} = event, tz) do
    [labeled(event, :gap_reason, "gap"), gap_bounds(event, tz)]
    |> Enum.reject(&is_nil/1)
    |> join_present()
  end

  defp gap(_event, _tz), do: nil

  # A missing bound keeps its arrow: "unknown from when" is itself information.
  defp gap_bounds(event, tz) do
    from = clock_or_nil(Map.get(event, :gap_from_ts), tz)
    to = clock_or_nil(Map.get(event, :gap_to_ts), tz)

    case {from, to} do
      {nil, nil} -> nil
      {from, nil} -> "#{from}→"
      {nil, to} -> "→#{to}"
      {from, to} -> "#{from}→#{to}"
    end
  end

  defp join_present([]), do: nil
  defp join_present(parts), do: Enum.join(parts, " ")

  # --- values -------------------------------------------------------------

  defp labeled(event, column, label) do
    case Map.get(event, column) do
      value when is_binary(value) and value != "" -> "#{label}=#{clipped_bare(value)}"
      _absent -> nil
    end
  end

  # EVERY rendered value is clipped, the unquoted ones included: one hostile
  # `type` or `gap_reason` could otherwise push a single line past the whole
  # input budget, and a batch that renders no line has no cursor to advance.
  defp clipped_bare(value) do
    {clipped, _clipped?} = clip(value)
    bare(clipped)
  end

  defp quoted(event, column, label) do
    case Map.get(event, column) do
      value when is_binary(value) and value != "" ->
        {clipped, _clipped?} = clip(value)
        "#{label}=#{quote_value(clipped)}"

      _absent ->
        nil
    end
  end

  defp quote_value(value), do: ~s("#{bare(value)}")

  # Explicit escaping, never inspect/1: inspect truncates long values head-only
  # (the clip above is what decides what survives) and its printable-limit
  # ellipsis is indistinguishable from the owner's own text.
  defp bare(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
  end

  defp blank?(value), do: is_nil(value) or value == ""

  # --- time ---------------------------------------------------------------

  defp clock(ts, tz), do: ts |> local(tz) |> Calendar.strftime("%H:%M:%S")

  defp clock_or_nil(ts, tz) when is_integer(ts), do: clock(ts, tz)
  defp clock_or_nil(_absent, _tz), do: nil

  defp local(ts, tz), do: ts |> DateTime.from_unix!(:millisecond) |> DateTime.shift_zone!(tz)

  # A byte offset can land inside a multi-byte character (a UTF-8 character is at
  # most 4 bytes, so at most 3 continuation bytes precede its lead byte).
  defp codepoint_boundary(binary, offset) do
    Enum.reduce_while(1..3//1, offset, fn _step, current ->
      if inside_character?(binary, current),
        do: {:cont, current - 1},
        else: {:halt, current}
    end)
  end

  defp inside_character?(binary, offset) do
    offset > 0 and offset < byte_size(binary) and continuation_byte?(:binary.at(binary, offset))
  end

  defp continuation_byte?(byte), do: byte >= 0x80 and byte <= 0xBF
end
