defmodule FermixCore.OpenLoops.Defaults do
  @moduledoc """
  The open-loop constants (MILESTONE_78 §06, §18).

  Pure data: no clock reads, no I/O, no configuration. Every tuning value lives
  here and is promoted to config only with evidence of per-owner variance, the
  standing rule for every tuning value. `horizon_class/3` and `slots/1` are the
  §18 slot table; `FermixCore.OpenLoops.Lifecycle` turns a slot into a time.

  Slot kinds:

    * `{:days_before, n}` — the local date `n` days before the date it matters,
      at the owner's active-hours start;
    * `{:days_after, n}` — the local date `n` days after it, likewise;
    * `{:before_hours_min, h}` — the next active-hours start that is still at
      least `h` hours before the instant the date has passed;
    * `:now` — the moment of capture (an imminent loop, rung 1 only).

  The last slot of a class is its hand-back.
  """

  @max_touches 3
  @max_live_loops 20
  @rung1_window_ms 3 * 60 * 60 * 1000
  @expiry_grace_ms 24 * 60 * 60 * 1000
  @fault_floor_ms 5_000

  @active_hours_default {~T[09:00:00], ~T[21:00:00]}
  @active_hours_lookback_days 28
  @active_hours_min_messages 40
  @active_hours_percentiles {15, 85}
  @active_hours_min_span_hours 6

  @checkin_max_iterations 6
  @checkin_watchdog_ms 120_000
  @send_timeout_ms 60_000

  @message_max_bytes 1_800
  @intention_max 500
  @why_it_matters_max 300
  @owner_words_max 240
  @reason_max 240
  @dedupe_key_max 240
  @closed_list_limit 25

  @imminent_seconds 48 * 60 * 60
  @long_days 14
  @medium_days 4

  @type horizon_class :: String.t()
  @type slot ::
          {:days_before, pos_integer()}
          | {:days_after, pos_integer()}
          | {:before_hours_min, pos_integer()}
          | :now

  @doc "Touches per loop, ever; the hand-back is the last (§06 caps)."
  @spec max_touches() :: pos_integer()
  def max_touches, do: @max_touches

  @doc "Live loops per owner; the next `open_loop_note` is refused."
  @spec max_live_loops() :: pos_integer()
  def max_live_loops, do: @max_live_loops

  @doc "How long after `next_touch_at` a due loop carries the due note (rung 1)."
  @spec rung1_window_ms() :: pos_integer()
  def rung1_window_ms, do: @rung1_window_ms

  @doc "The day the owner has to answer a hand-back before the loop expires."
  @spec expiry_grace_ms() :: pos_integer()
  def expiry_grace_ms, do: @expiry_grace_ms

  @doc "The floor under every re-arm on a fault path."
  @spec fault_floor_ms() :: pos_integer()
  def fault_floor_ms, do: @fault_floor_ms

  @doc "The window used when the owner's own messages are too few to derive one."
  @spec active_hours_default() :: {Time.t(), Time.t()}
  def active_hours_default, do: @active_hours_default

  @spec active_hours_lookback_days() :: pos_integer()
  def active_hours_lookback_days, do: @active_hours_lookback_days

  @spec active_hours_min_messages() :: pos_integer()
  def active_hours_min_messages, do: @active_hours_min_messages

  @spec active_hours_percentiles() :: {pos_integer(), pos_integer()}
  def active_hours_percentiles, do: @active_hours_percentiles

  @spec active_hours_min_span_hours() :: pos_integer()
  def active_hours_min_span_hours, do: @active_hours_min_span_hours

  @doc "The check-in run's iteration cap (the §22 follow-up's own bound)."
  @spec checkin_max_iterations() :: pos_integer()
  def checkin_max_iterations, do: @checkin_max_iterations

  @spec checkin_watchdog_ms() :: pos_integer()
  def checkin_watchdog_ms, do: @checkin_watchdog_ms

  @spec send_timeout_ms() :: pos_integer()
  def send_timeout_ms, do: @send_timeout_ms

  @doc "The most a spoken check-in may be; a longer one is refused, not cut."
  @spec message_max_bytes() :: pos_integer()
  def message_max_bytes, do: @message_max_bytes

  @spec intention_max() :: pos_integer()
  def intention_max, do: @intention_max

  @spec why_it_matters_max() :: pos_integer()
  def why_it_matters_max, do: @why_it_matters_max

  @spec owner_words_max() :: pos_integer()
  def owner_words_max, do: @owner_words_max

  @spec reason_max() :: pos_integer()
  def reason_max, do: @reason_max

  @spec dedupe_key_max() :: pos_integer()
  def dedupe_key_max, do: @dedupe_key_max

  @doc "How many settled or expired loops a `closed` listing carries."
  @spec closed_list_limit() :: pos_integer()
  def closed_list_limit, do: @closed_list_limit

  @doc """
  The horizon class, fixed at capture so a plan answer never changes which table
  applies (§18): under 48 hours from `said_at` to the instant the date has
  passed is imminent; otherwise the local days between the date said and the
  last local day on which it still matters decide it, 14 or more long, 4 to 13
  medium, fewer short.
  """
  @spec horizon_class(DateTime.t(), DateTime.t(), String.t()) :: horizon_class()
  def horizon_class(%DateTime{} = said_at, %DateTime{} = matters_by_at, zone)
      when is_binary(zone) do
    if DateTime.diff(matters_by_at, said_at, :second) < @imminent_seconds do
      "imminent"
    else
      matters_by_at |> last_local_day(zone) |> Date.diff(local_date(said_at, zone)) |> by_days()
    end
  end

  defp by_days(days) when days >= @long_days, do: "long"
  defp by_days(days) when days >= @medium_days, do: "medium"
  defp by_days(_days), do: "short"

  # `matters_by_at` is the instant the date has passed: the datetime itself, or
  # the start of the next local day. The microsecond before it is on the last
  # local day the loop still matters.
  defp last_local_day(matters_by_at, zone) do
    matters_by_at |> DateTime.add(-1, :microsecond) |> local_date(zone)
  end

  defp local_date(at, zone), do: at |> DateTime.shift_zone!(zone) |> DateTime.to_date()

  @doc "A class's slot table (§18). The last slot is the hand-back."
  @spec slots(horizon_class()) :: [slot()]
  def slots("long"), do: [{:days_before, 7}, {:days_before, 1}, {:days_after, 1}]
  def slots("medium"), do: [{:days_before, 3}, {:days_before, 1}, {:days_after, 1}]
  def slots("short"), do: [{:before_hours_min, 24}, {:days_after, 1}]
  def slots("imminent"), do: [:now]
end
