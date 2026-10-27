defmodule FermixCore.Cues.Gaps do
  @moduledoc """
  Fermix's one sentence for a gap (M60 §9.3, §9.5): what was not delivered, from
  where, since when and why. A cue run's prompt prefixes it with "Fermix: "
  (`Jobs.CueRun`); a gap notice with "Watcher <name>: " (`Cues.Notices`).
  """

  alias FermixCore.Clock

  # One phrase per `cue_gaps.reason` (the table's CHECK holds exactly these).
  @reasons %{
    "disconnect" => "the source was disconnected",
    "inbox_full" => "the inbox was full",
    "rate_limited" => "the source sent faster than its limit",
    "budget" => "the source reached its daily budget",
    "expired" => "they waited past their lifetime",
    "stale" => "they were too old when they arrived",
    "identity_conflict" => "they reused an id with different content",
    "watcher_removed" => "the watcher was removed",
    "read_limit" => "they were larger than Fermix reads",
    "page_limit" => "a page held more than Fermix reads at once",
    "backfill_limit" => "catching up reached its limit"
  }

  @doc """
  "12 items from eng-blogs were not delivered since 2026-10-10 09:14 UTC: the
  inbox was full." `gap` needs `count`, `source_ref`, `first_at` and a known
  `reason`.
  """
  @spec sentence(%{
          count: pos_integer(),
          source_ref: String.t(),
          first_at: DateTime.t(),
          reason: String.t()
        }) :: String.t()
  def sentence(%{count: count, source_ref: ref, first_at: %DateTime{} = first_at, reason: reason})
      when is_integer(count) and count > 0 and is_binary(ref) do
    "#{count} #{if count == 1, do: "item", else: "items"} from #{ref} " <>
      "#{if count == 1, do: "was", else: "were"} not delivered since " <>
      "#{Clock.stated_instant(first_at)}: #{Map.fetch!(@reasons, reason)}."
  end
end
