defmodule FermixCore.Meetings.SpeakerTimeline do
  @moduledoc """
  Pure, process-free speaker attribution for one meeting.

  The capture lane tells us two things: who is in the room (`note_roster/2`, a full
  snapshot) and who started speaking when (`note_active/3`, on the shared audio-sample
  clock). The transcription lane tells us what was said between two millisecond marks.
  `attribute/3` joins them, so attribution comes from the platform's own speaker
  identity — never from acoustic diarization.

  Rules pinned by the contract:

    * A later roster name for the same id wins (people rename themselves mid-meeting).
      Names are capped at 120 characters.
    * `note_active/3` opens an interval and closes the previous one at the same mark.
      A mark earlier than the newest interval's start is clamped forward to it —
      sources are monotonic, so this is a defensive floor, not a supported ordering.
    * `attribute/3` returns the speaker with the greatest total overlap of
      `[t0_ms, t1_ms)`. Ties go to the LATER-starting interval (the newer speaker
      is the one still talking). When nothing overlaps — no events yet, a segment
      inside a silent gap, or a zero-width/inverted window — the speaker covering
      `t0_ms` is used if any interval covers it.
    * An id that never appeared in a roster resolves to `"Unknown speaker"`, as does
      "nobody was speaking".

  State lives in the Session; this module holds none.
  """

  @unknown "Unknown speaker"
  @max_name_chars 120

  defstruct names: %{}, intervals: [], peak: 0

  @opaque t :: %__MODULE__{
            names: %{optional(String.t()) => String.t()},
            intervals: [{non_neg_integer(), non_neg_integer() | :open, String.t()}],
            peak: non_neg_integer()
          }

  @doc "An empty timeline: no names, no intervals, peak 0."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Records a full roster snapshot: id → name (later wins) and the participant peak.
  """
  @spec note_roster(t(), [%{id: String.t(), name: String.t()}]) :: t()
  def note_roster(%__MODULE__{} = timeline, participants) when is_list(participants) do
    names =
      Enum.reduce(participants, timeline.names, fn %{id: id, name: name}, acc
                                                   when is_binary(id) and is_binary(name) ->
        Map.put(acc, id, String.slice(name, 0, @max_name_chars))
      end)

    %{timeline | names: names, peak: max(timeline.peak, length(participants))}
  end

  @doc """
  Opens an active-speaker interval at `t_ms` and closes the previous one there.
  """
  @spec note_active(t(), String.t(), non_neg_integer()) :: t()
  def note_active(%__MODULE__{} = timeline, id, t_ms)
      when is_binary(id) and is_integer(t_ms) and t_ms >= 0 do
    at = clamp_forward(t_ms, timeline.intervals)
    %{timeline | intervals: [{at, :open, id} | close_newest(timeline.intervals, at)]}
  end

  @doc """
  The speaker name for the segment window `[t0_ms, t1_ms)`.
  """
  @spec attribute(t(), non_neg_integer(), non_neg_integer()) :: String.t()
  def attribute(%__MODULE__{} = timeline, t0_ms, t1_ms)
      when is_integer(t0_ms) and t0_ms >= 0 and is_integer(t1_ms) and t1_ms >= 0 do
    timeline.intervals
    |> overlap_totals(t0_ms, t1_ms)
    |> most_overlap()
    |> covering_when_none(timeline.intervals, t0_ms)
    |> name_of(timeline.names)
  end

  @doc "The largest roster snapshot seen (the meeting's participant peak)."
  @spec participants_peak(t()) :: non_neg_integer()
  def participants_peak(%__MODULE__{peak: peak}), do: peak

  # --- Private ---

  defp clamp_forward(t_ms, []), do: t_ms
  defp clamp_forward(t_ms, [{newest_start, _stop, _id} | _rest]), do: max(t_ms, newest_start)

  defp close_newest([], _at), do: []
  defp close_newest([{start, :open, id} | rest], at), do: [{start, at, id} | rest]

  # Intervals are newest-first and non-overlapping, so once one ends at or before
  # t0 every older interval does too — the scan halts there.
  defp overlap_totals(intervals, t0_ms, t1_ms) do
    Enum.reduce_while(intervals, [], fn {start, stop, id}, acc ->
      if ended_by?(stop, t0_ms) do
        {:halt, acc}
      else
        {:cont, add_overlap(acc, id, overlap_ms(start, stop, t0_ms, t1_ms))}
      end
    end)
  end

  defp ended_by?(:open, _t0_ms), do: false
  defp ended_by?(stop, t0_ms), do: stop <= t0_ms

  defp overlap_ms(start, stop, t0_ms, t1_ms) do
    finish = if stop == :open, do: t1_ms, else: min(stop, t1_ms)
    max(0, finish - max(start, t0_ms))
  end

  defp add_overlap(acc, _id, 0), do: acc

  defp add_overlap(acc, id, ms) do
    case List.keyfind(acc, id, 0) do
      nil -> acc ++ [{id, ms}]
      {^id, total} -> List.keyreplace(acc, id, 0, {id, total + ms})
    end
  end

  # The accumulator is newest-first, and a later entry must beat the running best
  # strictly — so a tie keeps the speaker whose interval started later.
  defp most_overlap([]), do: nil

  defp most_overlap(totals) do
    {id, _ms} =
      Enum.reduce(totals, fn {_id, ms} = entry, {_best_id, best_ms} = best ->
        if ms > best_ms, do: entry, else: best
      end)

    id
  end

  defp covering_when_none(nil, intervals, t0_ms) do
    Enum.find_value(intervals, fn {start, stop, id} ->
      if start <= t0_ms and not ended_by?(stop, t0_ms), do: id
    end)
  end

  defp covering_when_none(id, _intervals, _t0_ms), do: id

  defp name_of(nil, _names), do: @unknown
  defp name_of(id, names), do: Map.get(names, id, @unknown)
end
