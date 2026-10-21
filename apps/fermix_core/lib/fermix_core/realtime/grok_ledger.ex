defmodule FermixCore.Realtime.GrokLedger do
  @moduledoc """
  The spending ledger for one Grok voice call.

  Grok in server-VAD mode is priced two ways: $0.08 per minute the session is
  connected, and $0.004 per billable text item put into the conversation.
  Function-call outputs, audio items and `response.create` are not billable
  text, so this ledger has no way to count them: a counter that existed would
  sooner or later be called for one.

  Three facts shape it:

    * The meter is the connection, not the speech. Silence and mute do not
      pause it, so duration is wall time since connect, read from a monotonic
      clock the session passes in. `tick/2` never moves backwards.
    * A text item is counted when it is SENT, not when it is acknowledged: a
      socket that fails between the two may still have been charged, and
      accounting must not erase a possible charge. `text_item_acked/1` is
      bookkeeping only.
    * The vendor publishes no terminal usage for a session, so a call can only
      settle as `incomplete` with the local estimate. Claiming `complete`
      would invent a reconciliation that never happened.

  Money is integer millicents (1 cent = 1_000) end to end, rounded up once at
  the money boundary: the duration charge is one `ceil` over the whole
  connected span, never a sum of per-tick roundings. The wire renders seconds
  and cents with three decimals at the edge.

  Backend (agent) turns are counted, never priced: they run on whichever
  provider the operator configured, which may be a subscription with no
  per-turn price. `backend_cost` is therefore `"unknown"`, and unknown is not
  zero.
  """

  # $0.08 per connected minute and $0.004 per billable text item, in
  # millicents. The only rates in this module.
  @duration_millicents_per_minute 8_000
  @text_item_millicents 400
  @millicents_per_cent 1_000
  @ms_per_minute 60_000

  @type accounting :: :running | :incomplete

  @type t :: %__MODULE__{
          ceiling_millicents: pos_integer(),
          connected_at_ms: integer(),
          now_ms: integer(),
          text_items_sent: non_neg_integer(),
          text_items_acked: non_neg_integer(),
          backend_turns: non_neg_integer(),
          accounting: accounting()
        }

  @enforce_keys [:ceiling_millicents, :connected_at_ms, :now_ms]
  defstruct [
    :ceiling_millicents,
    :connected_at_ms,
    :now_ms,
    text_items_sent: 0,
    text_items_acked: 0,
    backend_turns: 0,
    accounting: :running
  ]

  @doc "A fresh ledger for a call connected at `now_ms` with a ceiling of `ceiling_cents`."
  @spec new(pos_integer(), integer()) :: t()
  def new(ceiling_cents, now_ms)
      when is_integer(ceiling_cents) and ceiling_cents > 0 and is_integer(now_ms) do
    %__MODULE__{
      ceiling_millicents: ceiling_cents * @millicents_per_cent,
      connected_at_ms: now_ms,
      now_ms: now_ms
    }
  end

  @doc """
  Advance the clock to `now_ms`. An earlier reading is ignored rather than
  trusted: the meter only runs forward, and a backwards step would lower a
  spend already observed.
  """
  @spec tick(t(), integer()) :: t()
  def tick(%__MODULE__{} = ledger, now_ms) when is_integer(now_ms) do
    %{ledger | now_ms: max(ledger.now_ms, now_ms)}
  end

  @doc "Count one billable text item at the moment it is sent."
  @spec text_item_sent(t()) :: t()
  def text_item_sent(%__MODULE__{} = ledger) do
    %{ledger | text_items_sent: ledger.text_items_sent + 1}
  end

  @doc """
  Record that the vendor acknowledged a text item already counted as sent.

  Bookkeeping only: the charge was counted at send and is never lowered. An
  acknowledgement with no sent item behind it is a session bug, and fails
  here rather than skewing the record.
  """
  @spec text_item_acked(t()) :: t()
  def text_item_acked(%__MODULE__{text_items_acked: acked, text_items_sent: sent} = ledger)
      when acked < sent do
    %{ledger | text_items_acked: acked + 1}
  end

  @doc "Count one completed backend delegation. Its cost is unknown, never zero."
  @spec record_backend_turn(t()) :: t()
  def record_backend_turn(%__MODULE__{} = ledger) do
    %{ledger | backend_turns: ledger.backend_turns + 1}
  end

  @doc "Milliseconds the session has been connected, as of the last tick."
  @spec connected_ms(t()) :: non_neg_integer()
  def connected_ms(%__MODULE__{} = ledger), do: ledger.now_ms - ledger.connected_at_ms

  @doc """
  Voice spend in integer millicents: the connected span priced per minute and
  rounded up once, plus every text item sent.
  """
  @spec voice_cost_millicents(t()) :: non_neg_integer()
  def voice_cost_millicents(%__MODULE__{} = ledger) do
    duration_millicents(connected_ms(ledger)) + text_millicents(ledger)
  end

  @doc """
  True once voice spend reaches the configured ceiling.

  Backend spend is deliberately excluded: it is unknown, and treating unknown
  as a number would either end calls early or never trip at all.
  """
  @spec over_ceiling?(t()) :: boolean()
  def over_ceiling?(%__MODULE__{} = ledger) do
    voice_cost_millicents(ledger) >= ledger.ceiling_millicents
  end

  @doc """
  Whether one more billable text item fits under the ceiling. Asked BEFORE the
  item is sent: once sent it is a possible charge whether or not it lands.
  """
  @spec affords_text_item?(t()) :: boolean()
  def affords_text_item?(%__MODULE__{} = ledger) do
    voice_cost_millicents(ledger) + @text_item_millicents <= ledger.ceiling_millicents
  end

  @doc """
  Whole milliseconds of connection left before the ceiling, at the current text
  item count.

  Rounded down, so a timer set for this span fires no earlier than the moment
  `over_ceiling?/1` turns true and the session finds the ceiling reached when
  it checks.
  """
  @spec ms_until_ceiling(t()) :: non_neg_integer()
  def ms_until_ceiling(%__MODULE__{} = ledger) do
    budget = ledger.ceiling_millicents - text_millicents(ledger)
    span = div(max(budget, 0) * @ms_per_minute, @duration_millicents_per_minute)
    max(span - connected_ms(ledger), 0)
  end

  @doc """
  Settle the call at `now_ms`.

  Always `incomplete`: the vendor sends no terminal usage, so the local
  estimate is the only number there is, and it is labelled as one.
  """
  @spec finalize(t(), integer()) :: t()
  def finalize(%__MODULE__{} = ledger, now_ms) when is_integer(now_ms) do
    %{tick(ledger, now_ms) | accounting: :incomplete}
  end

  @doc "The wire `usage` payload for a Grok call."
  @spec usage_payload(t()) :: map()
  def usage_payload(%__MODULE__{} = ledger) do
    %{
      status: "live",
      voice_seconds: round3(connected_ms(ledger) / 1_000),
      voice_cost_cents: round3(voice_cost_millicents(ledger) / @millicents_per_cent),
      voice_text_items: ledger.text_items_sent,
      backend_turns: ledger.backend_turns,
      backend_cost: "unknown",
      accounting: Atom.to_string(ledger.accounting)
    }
  end

  # One ceiling over the whole span, in integers: a per-tick ceil would bill a
  # fraction of a millicent on every tick.
  defp duration_millicents(ms) do
    div(ms * @duration_millicents_per_minute + @ms_per_minute - 1, @ms_per_minute)
  end

  defp text_millicents(ledger), do: ledger.text_items_sent * @text_item_millicents

  defp round3(value), do: Float.round(value / 1, 3)
end
