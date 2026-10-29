defmodule FermixCore.OpenLoops.Defaults do
  @moduledoc """
  The open-loop constants (MILESTONE_78 §06, §18; MILESTONE_83 §05, §07, §11).

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
    * `{:after_hours, h}` — `h` hours after the loop is armed, while that is
      still before the date has passed (an imminent loop, rung 1 only), so the
      loop is never raised in the conversation it came from;
    * `{:at_anchor}` — the loop's own anchor, the instant asking first feels
      natural (an `after` loop: something waited on or gone through).

  The last slot of a dated class is its hand-back, which a loop kept for
  conversation does not have (`slots/2`). An `after` loop has one slot and no
  hand-back; a second touch exists only when a plan or a not-yet with a new
  `ask_after` arms it, so no retry interval exists.
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

  @after_max_touches 2
  @conversation_window_ms 14 * 24 * 60 * 60 * 1000
  @ask_after_min_ms 3 * 60 * 60 * 1000
  @ask_after_max_ms 365 * 24 * 60 * 60 * 1000
  @reaches ~w(conversation message)

  @reactions_kept 50
  @note_replies %{this_loop: 1, others: 2}
  @checkin_replies %{this_loop: 1, others: 4}
  @checkin_owner_messages 6
  @checkin_owner_window_days 3
  @reply_window_ms 24 * 60 * 60 * 1000
  @reply_text_max 280
  @raised_with_max 280

  @imminent_seconds 48 * 60 * 60
  @long_days 14
  @medium_days 4

  @type horizon_class :: String.t()
  @type slot ::
          {:days_before, pos_integer()}
          | {:days_after, pos_integer()}
          | {:before_hours_min, pos_integer()}
          | {:after_hours, pos_integer()}
          | {:at_anchor}
  @type reach :: String.t()
  @type replies :: %{this_loop: non_neg_integer(), others: non_neg_integer()}

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

  @doc "Touches an `after` loop may ever have: its anchor's, and one a plan or not-yet arms."
  @spec after_max_touches() :: pos_integer()
  def after_max_touches, do: @after_max_touches

  @doc """
  How long a touch of a loop kept for conversation stays open on an `after`
  loop, and the most any `after` touch waits to be raised before it lapses.
  """
  @spec conversation_window_ms() :: pos_integer()
  def conversation_window_ms, do: @conversation_window_ms

  @doc "The nearest an `ask_after` may be: three hours on, as an imminent loop's window."
  @spec ask_after_min_ms() :: pos_integer()
  def ask_after_min_ms, do: @ask_after_min_ms

  @doc """
  The farthest an `ask_after`, or a plan on an `after` loop, may be: a year, a
  sanity bound, not taste, so a time the owner gave weeks or months out is kept.
  """
  @spec ask_after_max_ms() :: pos_integer()
  def ask_after_max_ms, do: @ask_after_max_ms

  @doc "How a loop may be raised: only in a conversation the owner starts, or also by message."
  @spec reaches() :: [reach()]
  def reaches, do: @reaches

  @doc "Follow-up reactions kept per owner, the newest."
  @spec reactions_kept() :: pos_integer()
  def reactions_kept, do: @reactions_kept

  @doc "Replies the due note shows: this loop's latest, then the most recent others."
  @spec note_replies() :: replies()
  def note_replies, do: @note_replies

  @doc "Replies a check-in run's input shows: this loop's latest, then the most recent others."
  @spec checkin_replies() :: replies()
  def checkin_replies, do: @checkin_replies

  @doc "The owner's own newest messages in the delivery conversation a check-in run's input shows."
  @spec checkin_owner_messages() :: pos_integer()
  def checkin_owner_messages, do: @checkin_owner_messages

  @doc "How many days back a check-in run reads the owner's own messages."
  @spec checkin_owner_window_days() :: pos_integer()
  def checkin_owner_window_days, do: @checkin_owner_window_days

  @doc "How long after a raise the owner's next message in that conversation counts as the reply."
  @spec reply_window_ms() :: pos_integer()
  def reply_window_ms, do: @reply_window_ms

  @spec reply_text_max() :: pos_integer()
  def reply_text_max, do: @reply_text_max

  @spec raised_with_max() :: pos_integer()
  def raised_with_max, do: @raised_with_max

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

  @doc "A class's slot table (§18). The last slot of a dated class is the hand-back."
  @spec slots(horizon_class()) :: [slot()]
  def slots("long"), do: [{:days_before, 7}, {:days_before, 1}, {:days_after, 1}]
  def slots("medium"), do: [{:days_before, 3}, {:days_before, 1}, {:days_after, 1}]
  def slots("short"), do: [{:before_hours_min, 24}, {:days_after, 1}]
  def slots("imminent"), do: [{:after_hours, 3}]
  def slots("after"), do: [{:at_anchor}]

  @doc """
  A class's slot table under a reach (M83 §05): a loop kept for conversation
  is never raised by message, so it has no hand-back.
  """
  @spec slots(horizon_class(), reach()) :: [slot()]
  def slots(class, "message"), do: slots(class)
  def slots(class, "conversation"), do: Enum.reject(slots(class), &handback_slot?/1)

  @doc "Whether a class under a reach ends in a hand-back."
  @spec handback?(horizon_class(), reach()) :: boolean()
  def handback?(class, reach), do: class |> slots(reach) |> List.last() |> handback_slot?()

  defp handback_slot?({:days_after, _days}), do: true
  defp handback_slot?(_slot), do: false
end
