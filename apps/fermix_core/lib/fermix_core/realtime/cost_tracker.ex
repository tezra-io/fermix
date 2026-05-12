defmodule FermixCore.Realtime.CostTracker do
  @moduledoc """
  Tracks estimated and reported Realtime session usage.

  Per-token rates below are the single named source of truth for Realtime
  pricing. They must be reviewed when `Config.model` is bumped (see
  `MILESTONE_9_1_REALTIME_VOICE.md` Open Issue #8). Rates are dollars per
  million tokens for `gpt-realtime-2` as of 2026-05-10.
  """

  alias FermixCore.Realtime.Config

  @input_audio_price_dollars_per_million_tokens 32.0
  @cached_input_audio_price_dollars_per_million_tokens 0.40
  @input_text_price_dollars_per_million_tokens 4.0
  @output_audio_price_dollars_per_million_tokens 64.0
  @output_text_price_dollars_per_million_tokens 16.0
  @input_token_ms 100

  @type usage :: %{
          input_audio_ms: non_neg_integer(),
          input_audio_tokens: non_neg_integer(),
          cost_cents: float()
        }

  @type t :: %__MODULE__{
          config: Config.t(),
          estimated: usage(),
          reported: %{cost_cents: float()}
        }

  defstruct config: nil,
            estimated: %{input_audio_ms: 0, input_audio_tokens: 0, cost_cents: 0.0},
            reported: %{cost_cents: 0.0}

  @spec new(Config.t()) :: t()
  def new(%Config{} = config), do: %__MODULE__{config: config}

  @spec add_input_audio_ms(t(), non_neg_integer()) :: t()
  def add_input_audio_ms(%__MODULE__{} = tracker, ms) when is_integer(ms) and ms >= 0 do
    input_audio_ms = tracker.estimated.input_audio_ms + ms
    input_audio_tokens = div(input_audio_ms + @input_token_ms - 1, @input_token_ms)
    cost_cents = tokens_cents(input_audio_tokens, @input_audio_price_dollars_per_million_tokens)

    put_in(tracker.estimated, %{
      input_audio_ms: input_audio_ms,
      input_audio_tokens: input_audio_tokens,
      cost_cents: cost_cents
    })
  end

  @spec put_estimated_cost_cents(t(), float() | integer()) :: t()
  def put_estimated_cost_cents(%__MODULE__{} = tracker, cents)
      when is_number(cents) and cents >= 0 do
    put_in(tracker.estimated.cost_cents, cents / 1)
  end

  @spec put_reported_tokens(t(), map()) :: t()
  def put_reported_tokens(%__MODULE__{} = tracker, %{} = usage) do
    put_in(tracker.reported.cost_cents, reported_cost_cents(usage))
  end

  @spec enforce_limits(t()) :: :ok | {:stop, :cost_limit | :input_audio_limit}
  def enforce_limits(%__MODULE__{} = tracker) do
    cond do
      input_audio_seconds(tracker) > tracker.config.max_input_audio_seconds_per_session ->
        {:stop, :input_audio_limit}

      max_cost_cents(tracker) > tracker.config.max_estimated_cost_cents_per_session ->
        {:stop, :cost_limit}

      true ->
        :ok
    end
  end

  defp reported_cost_cents(usage) do
    input_details = Map.get(usage, "input_token_details", %{})
    output_details = Map.get(usage, "output_token_details", %{})

    cached = non_negative_int(Map.get(input_details, "cached_tokens", 0))
    audio_in = non_negative_int(Map.get(input_details, "audio_tokens", 0))
    text_in = non_negative_int(Map.get(input_details, "text_tokens", 0))
    audio_out = non_negative_int(Map.get(output_details, "audio_tokens", 0))
    text_out = non_negative_int(Map.get(output_details, "text_tokens", 0))

    uncached_audio_in = max(0, audio_in - cached)

    tokens_cents(uncached_audio_in, @input_audio_price_dollars_per_million_tokens) +
      tokens_cents(cached, @cached_input_audio_price_dollars_per_million_tokens) +
      tokens_cents(text_in, @input_text_price_dollars_per_million_tokens) +
      tokens_cents(audio_out, @output_audio_price_dollars_per_million_tokens) +
      tokens_cents(text_out, @output_text_price_dollars_per_million_tokens)
  end

  defp tokens_cents(tokens, dollars_per_million) do
    tokens * dollars_per_million / 1_000_000 * 100
  end

  defp non_negative_int(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(_value), do: 0

  defp input_audio_seconds(tracker), do: tracker.estimated.input_audio_ms / 1_000

  defp max_cost_cents(tracker) do
    max(tracker.estimated.cost_cents, tracker.reported.cost_cents)
  end
end
