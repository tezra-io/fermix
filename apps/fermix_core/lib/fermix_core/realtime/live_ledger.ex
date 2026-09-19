defmodule FermixCore.Realtime.LiveLedger do
  @moduledoc """
  The duration ledger for one Live voice call.

  Live is priced by the clock — $0.05 per session minute, charged per second —
  so this ledger counts SECONDS, never tokens. Expressing a voice minute as
  tokens would invent a unit the invoice does not have.

  Two facts make it a module rather than a counter:

    * `session.usage.updated` carries a CUMULATIVE `usage.seconds`. Summing
      snapshots inflates a call without bound, so `observe_usage/3` replaces the
      previous value and refuses to move backwards (a regression is recorded on
      `regressed?` rather than silently accepted — accounting that went down is
      a fact the trace must keep).
    * Snapshots arrive irregularly and a silent call may go minutes without one.
      `tick/2` therefore adds the LOCAL elapsed time since the last snapshot, so
      silence still reaches the spending ceiling. It recomputes that elapsed
      span every time rather than accumulating it, which is what keeps it from
      becoming a second, drifting sum.

  Money is integer millicents (1 cent = 1_000) end to end: a per-second price of
  a per-minute rate is not representable in cents, and floats accumulate error
  over a long call. The wire renders cents with three decimals at the edge.

  Backend (agent) turns are counted, never priced: a Live delegation runs on
  whichever provider the operator configured, which may be a subscription with
  no per-turn price at all. `backend_cost` is therefore `"unknown"`, and unknown
  is not zero.
  """

  # $0.05 per session minute, in millicents. The only rate in this module.
  @rate_millicents_per_minute 5_000
  @millicents_per_cent 1_000
  @seconds_per_minute 60

  @type accounting :: :running | :complete | :incomplete

  @type t :: %__MODULE__{
          ceiling_millicents: pos_integer(),
          provider_seconds: number(),
          local_ms: non_neg_integer(),
          observed_at_ms: integer(),
          regressed?: boolean(),
          backend_turns: non_neg_integer(),
          backend_input_tokens: non_neg_integer(),
          backend_output_tokens: non_neg_integer(),
          accounting: accounting()
        }

  defstruct ceiling_millicents: @rate_millicents_per_minute,
            provider_seconds: 0,
            local_ms: 0,
            observed_at_ms: 0,
            regressed?: false,
            backend_turns: 0,
            backend_input_tokens: 0,
            backend_output_tokens: 0,
            accounting: :running

  @doc "A fresh ledger for a call whose estimated ceiling is `ceiling_cents`."
  @spec new(pos_integer(), integer()) :: t()
  def new(ceiling_cents, now_ms) when is_integer(ceiling_cents) and ceiling_cents > 0 do
    %__MODULE__{
      ceiling_millicents: ceiling_cents * @millicents_per_cent,
      observed_at_ms: now_ms
    }
  end

  @doc """
  Apply one cumulative `session.usage.updated` snapshot.

  A snapshot lower than the last is a provider regression: it is ignored and
  flagged, because dropping the total would under-report a call that is still
  being billed.
  """
  @spec observe_usage(t(), number(), integer()) :: t()
  def observe_usage(%__MODULE__{} = ledger, seconds, now_ms)
      when is_number(seconds) and seconds >= 0 and is_integer(now_ms) do
    if seconds < ledger.provider_seconds do
      %{ledger | regressed?: true}
    else
      %{ledger | provider_seconds: seconds, local_ms: 0, observed_at_ms: now_ms}
    end
  end

  @doc """
  Account for the time since the last provider snapshot.

  Recomputed, never accumulated: two ticks without a snapshot in between
  describe the same span, and adding them would double-bill silence.
  """
  @spec tick(t(), integer()) :: t()
  def tick(%__MODULE__{} = ledger, now_ms) when is_integer(now_ms) do
    %{ledger | local_ms: max(0, now_ms - ledger.observed_at_ms)}
  end

  @doc """
  Settle the call.

  `seconds` is the provider's terminal `session.closed` duration; `nil` means it
  never arrived, which is recorded as INCOMPLETE accounting rather than
  overwritten with a confident number. A terminal duration never lowers the
  total already observed.
  """
  @spec finalize(t(), number() | nil) :: t()
  def finalize(%__MODULE__{} = ledger, nil), do: %{ledger | accounting: :incomplete}

  def finalize(%__MODULE__{} = ledger, seconds) when is_number(seconds) and seconds >= 0 do
    %{
      ledger
      | provider_seconds: max(ledger.provider_seconds, seconds),
        local_ms: 0,
        accounting: :complete
    }
  end

  @doc "Billed voice duration: the provider's total plus the local span since it."
  @spec voice_seconds(t()) :: float()
  def voice_seconds(%__MODULE__{} = ledger) do
    provider = ledger.provider_seconds / 1
    max(provider, provider + ledger.local_ms / 1_000)
  end

  @doc "Voice spend in integer millicents, at whole billed seconds."
  @spec voice_cost_millicents(t()) :: non_neg_integer()
  def voice_cost_millicents(%__MODULE__{} = ledger) do
    div(ceil(voice_seconds(ledger)) * @rate_millicents_per_minute, @seconds_per_minute)
  end

  @doc """
  Count one completed backend delegation.

  Tokens are totalled for the record; the cost is not, because the backend
  provider may be a subscription. `usage` may be any shape the bridge returns —
  absent counters are simply not counted.
  """
  @spec record_backend_turn(t(), map()) :: t()
  def record_backend_turn(%__MODULE__{} = ledger, usage) when is_map(usage) do
    %{
      ledger
      | backend_turns: ledger.backend_turns + 1,
        backend_input_tokens: ledger.backend_input_tokens + tokens(usage, :input_tokens),
        backend_output_tokens: ledger.backend_output_tokens + tokens(usage, :output_tokens)
    }
  end

  @doc """
  True once voice spend alone reaches the configured ceiling.

  Backend spend is deliberately excluded: it is unknown, and treating unknown as
  a number would either kill calls early or never trip at all.
  """
  @spec over_ceiling?(t()) :: boolean()
  def over_ceiling?(%__MODULE__{} = ledger) do
    voice_cost_millicents(ledger) >= ledger.ceiling_millicents
  end

  @doc "The wire `usage` payload for a Live call (protocol v2)."
  @spec usage_payload(t()) :: map()
  def usage_payload(%__MODULE__{} = ledger) do
    %{
      status: "live",
      voice_seconds: round3(voice_seconds(ledger)),
      voice_cost_cents: round3(voice_cost_millicents(ledger) / @millicents_per_cent),
      backend_turns: ledger.backend_turns,
      backend_cost: "unknown",
      accounting: Atom.to_string(ledger.accounting)
    }
  end

  defp tokens(usage, key) do
    case Map.get(usage, key, Map.get(usage, Atom.to_string(key))) do
      value when is_integer(value) and value >= 0 -> value
      _other -> 0
    end
  end

  defp round3(value), do: Float.round(value / 1, 3)
end
