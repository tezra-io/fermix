defmodule FermixCore.ComputerHistory.Summarizer.Sessions do
  @moduledoc """
  Splits a spool read into **sittings** (MILESTONE_32 §24.2). Pure: no repo, no
  clock of its own, no logging — the caller passes `now` and decides what to do
  with the answer.

  A sitting is a contiguous run of events: consecutive `ts` closer than
  `@idle_gap_ms`, not crossed by a sleep / lock / user-switch boundary, and no
  wider than `@session_max_ms`. The boundary event that ends a sitting belongs to
  **no** sitting — it is not activity — but its id is consumed with the sitting
  before it, so the cursor moves past it exactly once.

  A sitting is **closed** when something follows it (another sitting or a
  boundary), when the read filled its limit (the read boundary cuts it, and the
  remainder becomes the next sitting), or when `now - last_ts >= @idle_gap_ms`.
  Only a closed sitting may be summarized; the trailing open one waits, and the
  caller records its first `ts` so `/history status` can say what it is waiting
  for.

  Events are ordered by `{ts, id}` here, not by id: a late-flushed event joins
  the sitting its `ts` falls into. The cursor stays an id high-water mark, so an
  event whose id is *overtaken* by that ordering is reported back in
  `overtaken_ids` — the caller logs it rather than losing it silently.
  """

  @idle_gap_ms :timer.minutes(10)
  @session_max_ms :timer.minutes(90)
  # Machine-level transitions: the owner stopped, so the sitting stopped.
  @boundary_kinds ["system.sleep", "session.locked", "user.switched"]

  @type session :: %{
          events: [map()],
          consumed_ids: [integer()],
          overtaken_ids: [integer()]
        }
  @type decision :: {:session, session()} | {:boundaries, [integer()]} | :wait
  @type open_state :: {:open, integer()} | :none | :unknown

  @doc "The idle threshold that both splits and closes a sitting."
  @spec idle_gap_ms() :: pos_integer()
  def idle_gap_ms, do: @idle_gap_ms

  @doc "The widest a single sitting may get before the ceiling splits it."
  @spec session_max_ms() :: pos_integer()
  def session_max_ms, do: @session_max_ms

  @doc "The event kinds that end a sitting and belong to none."
  @spec boundary_kinds() :: [String.t()]
  def boundary_kinds, do: @boundary_kinds

  @doc """
  The next closed sitting in `events` (a read, in id order), plus what the caller
  should record about the trailing open one. `now_ms` is epoch ms; `truncated?`
  says the read filled its limit, in which case the trailing sitting is cut at
  the read boundary and the open state is unknowable from this read.
  """
  @spec next_closed([map()], integer(), boolean()) :: {decision(), open_state()}
  def next_closed(events, now_ms, truncated?)
      when is_list(events) and is_integer(now_ms) and is_boolean(truncated?) do
    groups =
      events
      |> Enum.sort_by(&{&1.ts, &1.id})
      |> group()

    {decide(groups, now_ms, truncated?), open_state(groups, now_ms, truncated?)}
  end

  # --- grouping -----------------------------------------------------------

  defp group(events) do
    events
    |> Enum.reduce([], &place/2)
    |> Enum.reverse()
    |> Enum.map(&finish_group/1)
  end

  defp place(event, groups) do
    if boundary?(event),
      do: [{:boundary, event} | groups],
      else: place_in_sitting(event, groups)
  end

  # Accumulated newest-first with both bounds carried, so neither the gap test
  # nor the ceiling test has to walk the sitting it is extending.
  defp place_in_sitting(event, [{:session, sitting} | rest] = groups) do
    if event.ts - sitting.last_ts <= @idle_gap_ms and
         event.ts - sitting.first_ts <= @session_max_ms do
      [{:session, %{sitting | events: [event | sitting.events], last_ts: event.ts}} | rest]
    else
      [new_sitting(event) | groups]
    end
  end

  defp place_in_sitting(event, groups), do: [new_sitting(event) | groups]

  defp new_sitting(event),
    do: {:session, %{events: [event], first_ts: event.ts, last_ts: event.ts}}

  defp finish_group({:session, sitting}), do: {:session, Enum.reverse(sitting.events)}
  defp finish_group({:boundary, _event} = group), do: group

  defp boundary?(%{type: type}), do: type in @boundary_kinds

  # --- decision -----------------------------------------------------------

  defp decide(groups, now_ms, truncated?) do
    case split_at_first_closed(groups, [], now_ms, truncated?) do
      {prefix, sitting, trailing} -> session_decision(groups, prefix, sitting, trailing)
      :none -> nothing_to_summarize(groups)
    end
  end

  # Walks oldest-first for the first CLOSED sitting, collecting what precedes it
  # (leading boundaries) and the boundaries immediately after it — all of which
  # its write consumes.
  defp split_at_first_closed([], _prefix, _now_ms, _truncated?), do: :none

  defp split_at_first_closed([{:boundary, _event} = group | rest], prefix, now_ms, truncated?),
    do: split_at_first_closed(rest, [group | prefix], now_ms, truncated?)

  defp split_at_first_closed([{:session, events} = group | rest], prefix, now_ms, truncated?) do
    if closed?(events, rest, now_ms, truncated?) do
      {trailing, _later} = Enum.split_while(rest, &boundary_group?/1)
      {Enum.reverse(prefix), events, trailing}
    else
      split_at_first_closed(rest, [group | prefix], now_ms, truncated?)
    end
  end

  defp closed?(_events, [_next | _rest], _now_ms, _truncated?), do: true
  defp closed?(_events, [], _now_ms, true), do: true

  defp closed?(events, [], now_ms, false),
    do: now_ms - last_event(events).ts >= @idle_gap_ms

  defp session_decision(groups, prefix, events, trailing) do
    consumed_ids = ids(prefix) ++ ids([{:session, events}]) ++ ids(trailing)

    {:session,
     %{
       events: events,
       consumed_ids: consumed_ids,
       overtaken_ids: overtaken_ids(groups, consumed_ids)
     }}
  end

  # Ids the cursor will pass without their event having been summarized: only
  # reachable when a newer-ts event was written to the spool BEFORE an older-ts
  # one. The caller logs them; nothing here hides them.
  defp overtaken_ids(groups, consumed_ids) do
    cursor = Enum.max(consumed_ids)
    consumed = MapSet.new(consumed_ids)

    groups
    |> ids()
    |> Enum.filter(&(&1 <= cursor and not MapSet.member?(consumed, &1)))
  end

  defp nothing_to_summarize([]), do: :wait

  defp nothing_to_summarize(groups) do
    if Enum.all?(groups, &boundary_group?/1),
      do: {:boundaries, ids(groups)},
      else: :wait
  end

  # --- the open tail ------------------------------------------------------

  defp open_state(_groups, _now_ms, true), do: :unknown
  defp open_state([], _now_ms, false), do: :none

  defp open_state(groups, now_ms, false) do
    case List.last(groups) do
      {:session, events} -> open_or_none(events, now_ms)
      {:boundary, _event} -> :none
    end
  end

  defp open_or_none(events, now_ms) do
    if now_ms - last_event(events).ts < @idle_gap_ms,
      do: {:open, hd(events).ts},
      else: :none
  end

  # --- helpers ------------------------------------------------------------

  defp boundary_group?({:boundary, _event}), do: true
  defp boundary_group?({:session, _events}), do: false

  defp ids(groups), do: Enum.flat_map(groups, &group_ids/1)

  defp group_ids({:session, events}), do: Enum.map(events, & &1.id)
  defp group_ids({:boundary, event}), do: [event.id]

  defp last_event(events), do: List.last(events)
end
