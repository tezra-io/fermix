defmodule FermixCore.Realtime.CostTracker do
  @moduledoc """
  Tracks estimated and reported Realtime session usage.

  Per-token rates below are the single named source of truth for Realtime
  pricing, keyed by MODEL (`MILESTONE_9_1_REALTIME_VOICE.md` Open Issue #8). Every
  model `Realtime.Config` accepts must appear in `@rates` — a test pins that — so
  adding a model without pricing fails the suite rather than silently metering a
  call at another model's rates. Dollars per million tokens.

  Reported usage ACCUMULATES per response, deduplicated by `response.id`: a call
  produces many responses, so overwriting with the latest one (what this module
  used to do) under-reported a long call by everything that came before. `image`
  usage is additionally attributed to the screen feed, which is what makes the
  feed's own budget ceiling (`feed_over_budget?/1`) enforceable.
  """

  alias FermixCore.Realtime.Config

  # Cached input is billed at ONE rate per model here rather than per modality
  # (audio/text/image each have their own cached rate upstream). It is a small
  # correction on a spend ceiling, and collapsing it keeps one table readable;
  # the uncached rates — which dominate — are exact.
  @rates %{
    "gpt-realtime-2" => %{
      audio_in: 32.0,
      cached_in: 0.40,
      text_in: 4.0,
      image_in: 5.0,
      audio_out: 64.0,
      text_out: 16.0
    },
    "gpt-realtime-2.1" => %{
      audio_in: 32.0,
      cached_in: 0.40,
      text_in: 4.0,
      image_in: 5.0,
      audio_out: 64.0,
      text_out: 24.0
    },
    "gpt-realtime-2.1-mini" => %{
      audio_in: 10.0,
      cached_in: 0.30,
      text_in: 0.60,
      image_in: 0.80,
      audio_out: 20.0,
      text_out: 2.40
    }
  }

  @input_token_ms 100

  # Input modalities that can be cached, dearest first — the order cached tokens
  # are attributed in when the payload does not break them down.
  @cached_modalities ~w(audio_tokens text_tokens image_tokens)

  # The screen feed may spend at most this share of the call's ONE budget. Not a
  # second config key: a fixed fraction keeps "how much may this call cost" a
  # single operator decision while still stopping the feed before it eats the
  # whole call (M9.5 §7).
  @feed_budget_share 0.5

  @type usage :: %{
          input_audio_ms: non_neg_integer(),
          input_audio_tokens: non_neg_integer(),
          cost_cents: float()
        }

  @type feed_usage :: %{image_tokens: non_neg_integer(), cost_cents: float()}

  @type t :: %__MODULE__{
          config: Config.t(),
          estimated: usage(),
          reported: %{cost_cents: float()},
          feed: feed_usage(),
          counted_responses: MapSet.t(String.t())
        }

  defstruct config: nil,
            estimated: %{input_audio_ms: 0, input_audio_tokens: 0, cost_cents: 0.0},
            reported: %{cost_cents: 0.0},
            feed: %{image_tokens: 0, cost_cents: 0.0},
            counted_responses: MapSet.new()

  @doc "The per-model rate table (the pricing contract a test pins to `Config.valid_models/0`)."
  @spec rates() :: %{String.t() => map()}
  def rates, do: @rates

  @spec new(Config.t()) :: t()
  def new(%Config{} = config), do: %__MODULE__{config: config}

  @spec add_input_audio_ms(t(), non_neg_integer()) :: t()
  def add_input_audio_ms(%__MODULE__{} = tracker, ms) when is_integer(ms) and ms >= 0 do
    input_audio_ms = tracker.estimated.input_audio_ms + ms
    input_audio_tokens = div(input_audio_ms + @input_token_ms - 1, @input_token_ms)
    cost_cents = tokens_cents(input_audio_tokens, rate(tracker, :audio_in))

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

  @doc """
  Fold one `response.done` usage payload into the call's reported total.

  Deduplicated by `response_id` so a repeated event cannot double-bill. A `nil` id
  (a payload without one) is still counted — under-reporting a real spend is the
  worse failure — but cannot be deduplicated.
  """
  @spec add_reported_usage(t(), String.t() | nil, map()) :: t()
  def add_reported_usage(%__MODULE__{} = tracker, response_id, %{} = usage)
      when is_binary(response_id) or is_nil(response_id) do
    if counted?(tracker, response_id) do
      tracker
    else
      tracker
      |> mark_counted(response_id)
      |> add_costs(split_costs(tracker, usage))
    end
  end

  @doc """
  Whether the screen feed has spent its share of the call budget. The feed stops
  FIRST and the call continues without it — losing the eyes is recoverable and
  audible; losing the call mid-sentence is neither.
  """
  @spec feed_over_budget?(t()) :: boolean()
  def feed_over_budget?(%__MODULE__{} = tracker) do
    tracker.feed.cost_cents >=
      tracker.config.max_estimated_cost_cents_per_session * @feed_budget_share
  end

  @spec enforce_limits(t()) :: :ok | {:stop, :cost_limit}
  def enforce_limits(%__MODULE__{} = tracker) do
    if max_cost_cents(tracker) > tracker.config.max_estimated_cost_cents_per_session do
      {:stop, :cost_limit}
    else
      :ok
    end
  end

  defp counted?(_tracker, nil), do: false
  defp counted?(tracker, response_id), do: MapSet.member?(tracker.counted_responses, response_id)

  defp mark_counted(tracker, nil), do: tracker

  defp mark_counted(tracker, response_id),
    do: %{tracker | counted_responses: MapSet.put(tracker.counted_responses, response_id)}

  # Image tokens are billed like any other input token, but attributed to the feed
  # as WELL as the call: retained frames are re-read on every later response, so
  # the feed's line grows with the real cost of keeping eyes open rather than only
  # with the instant a frame was sent.
  # `cached_tokens` is a SUBSET of the per-modality input totals, split out by
  # `cached_tokens_details`. Subtracting the whole of it from AUDIO alone billed
  # every cached text token twice — once at the full text rate and again at the
  # cached rate — and a Realtime call re-sends and re-caches its system prompt and
  # tool schemas on EVERY response, so the error compounds with conversation
  # length. Live effect: a two-minute call over-reported several-fold and tripped
  # the session cost ceiling, which tore the call down mid-sentence.
  defp split_costs(tracker, usage) do
    input = Map.get(usage, "input_token_details", %{})
    output = Map.get(usage, "output_token_details", %{})

    cached = cached_split(input, non_negative_int(Map.get(input, "cached_tokens", 0)))
    image_in = uncached(input, cached, "image_tokens")
    image_cents = tokens_cents(image_in, rate(tracker, :image_in))

    total_cents =
      tokens_cents(uncached(input, cached, "audio_tokens"), rate(tracker, :audio_in)) +
        tokens_cents(uncached(input, cached, "text_tokens"), rate(tracker, :text_in)) +
        tokens_cents(billed_cached(cached), rate(tracker, :cached_in)) +
        tokens_cents(out_tokens(output, "audio_tokens"), rate(tracker, :audio_out)) +
        tokens_cents(out_tokens(output, "text_tokens"), rate(tracker, :text_out)) +
        image_cents

    %{total_cents: total_cents, image_cents: image_cents, image_tokens: image_in}
  end

  # Cached input is billed ONCE, at the cached rate, and the same tokens are
  # subtracted from their modality's total first — because `cached_tokens` is a
  # SUBSET of those totals, not an extra line. Getting this wrong is expensive in
  # exactly one direction: crediting the cached total to audio alone left every
  # cached TEXT token billed at the full text rate as well, and a Realtime call
  # re-sends and re-caches its system prompt on every response, so the error grew
  # with the conversation until it tripped the session cost ceiling mid-call.
  defp cached_split(input, cached_total) do
    case Map.get(input, "cached_tokens_details") do
      %{} = details ->
        Map.new(@cached_modalities, &{&1, non_negative_int(Map.get(details, &1, 0))})

      _absent ->
        spread_cached(input, cached_total)
    end
  end

  # No per-modality detail: attribute audio-first (the dominant and dearest input
  # on a voice call), never taking more than a modality actually reported. An
  # approximation of the split — but never a double-bill, which is the property
  # that matters for a spend ceiling.
  defp spread_cached(input, cached_total) do
    {split, _remaining} =
      Enum.map_reduce(@cached_modalities, cached_total, fn key, remaining ->
        taken = min(remaining, non_negative_int(Map.get(input, key, 0)))
        {{key, taken}, remaining - taken}
      end)

    Map.new(split)
  end

  defp uncached(totals, cached, key) do
    max(0, non_negative_int(Map.get(totals, key, 0)) - Map.get(cached, key, 0))
  end

  defp billed_cached(cached), do: cached |> Map.values() |> Enum.sum()

  defp out_tokens(output, key), do: non_negative_int(Map.get(output, key, 0))

  defp add_costs(tracker, costs) do
    %{
      tracker
      | reported: %{cost_cents: tracker.reported.cost_cents + costs.total_cents},
        feed: %{
          image_tokens: tracker.feed.image_tokens + costs.image_tokens,
          cost_cents: tracker.feed.cost_cents + costs.image_cents
        }
    }
  end

  defp tokens_cents(tokens, dollars_per_million) do
    tokens * dollars_per_million / 1_000_000 * 100
  end

  # `Config.validate!/1` restricts the model to `Config.valid_models/0` and a test
  # pins every one of those to an entry here, so a miss is a caught build-time bug
  # rather than a live mis-priced call.
  defp rate(%__MODULE__{config: %Config{model: model}}, key) do
    @rates |> Map.fetch!(model) |> Map.fetch!(key)
  end

  defp non_negative_int(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(_value), do: 0

  defp max_cost_cents(%__MODULE__{estimated: estimated, reported: reported}) do
    max(estimated.cost_cents, reported.cost_cents)
  end
end
