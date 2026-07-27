defmodule FermixCore.Realtime.CostTrackerTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.CostTracker

  test "estimates input audio tokens from committed audio duration" do
    tracker =
      []
      |> Config.normalize()
      |> CostTracker.new()
      |> CostTracker.add_input_audio_ms(60_000)

    assert tracker.estimated.input_audio_tokens == 600
    assert tracker.estimated.input_audio_ms == 60_000
  end

  test "enforces cost cap against max estimated or reported cost" do
    config = Config.normalize(max_estimated_cost_cents_per_session: 25)

    estimated =
      config
      |> CostTracker.new()
      |> CostTracker.put_estimated_cost_cents(30.0)

    # 500_000 audio output tokens at $64/1M = $32 = 3_200 cents
    reported =
      config
      |> CostTracker.new()
      |> CostTracker.add_reported_usage("resp_1", %{
        "output_token_details" => %{"audio_tokens" => 500_000}
      })

    assert {:stop, :cost_limit} = CostTracker.enforce_limits(estimated)
    assert {:stop, :cost_limit} = CostTracker.enforce_limits(reported)
  end

  test "add_reported_usage prices audio/text input/output and credits cached input" do
    tracker =
      []
      |> Config.normalize()
      |> CostTracker.new()
      |> CostTracker.add_reported_usage("resp_1", %{
        "input_token_details" => %{
          "audio_tokens" => 1_000_000,
          "text_tokens" => 1_000_000,
          "cached_tokens" => 500_000
        },
        "output_token_details" => %{
          "audio_tokens" => 1_000_000,
          "text_tokens" => 1_000_000
        }
      })

    # uncached audio in (500k * $32/M) = $16
    # cached audio in (500k * $0.40/M) = $0.20
    # text in (1M * $4/M) = $4
    # audio out (1M * $64/M) = $64
    # text out (1M * $16/M) = $16
    # total = $100.20 = 10_020.0 cents
    assert_in_delta tracker.reported.cost_cents, 10_020.0, 0.01
  end

  test "add_reported_usage treats missing or non-integer fields as zero" do
    tracker =
      []
      |> Config.normalize()
      |> CostTracker.new()
      |> CostTracker.add_reported_usage("resp_1", %{})

    assert tracker.reported.cost_cents == 0.0
  end

  test "does not enforce a local input audio duration cap" do
    tracker =
      [max_estimated_cost_cents_per_session: 10_000]
      |> Config.normalize()
      |> CostTracker.new()
      |> CostTracker.add_input_audio_ms(60 * 60 * 1_000)

    assert :ok = CostTracker.enforce_limits(tracker)
  end

  # The regression the screen feed depends on: a call has MANY responses, and the
  # old overwrite semantics reported only the most recent one.
  test "reported usage accumulates across responses" do
    usage = %{"output_token_details" => %{"text_tokens" => 1_000_000}}

    tracker =
      []
      |> Config.normalize()
      |> CostTracker.new()
      |> CostTracker.add_reported_usage("resp_1", usage)
      |> CostTracker.add_reported_usage("resp_2", usage)
      |> CostTracker.add_reported_usage("resp_3", usage)

    # 3 x 1M text-out tokens at $16/1M = $48 = 4_800 cents
    assert_in_delta tracker.reported.cost_cents, 4_800.0, 0.01
  end

  test "the same response id is never billed twice" do
    usage = %{"output_token_details" => %{"text_tokens" => 1_000_000}}

    tracker =
      []
      |> Config.normalize()
      |> CostTracker.new()
      |> CostTracker.add_reported_usage("resp_1", usage)
      |> CostTracker.add_reported_usage("resp_1", usage)

    assert_in_delta tracker.reported.cost_cents, 1_600.0, 0.01
  end

  test "a response with no id is still counted (under-reporting spend is worse)" do
    usage = %{"output_token_details" => %{"text_tokens" => 1_000_000}}

    tracker =
      []
      |> Config.normalize()
      |> CostTracker.new()
      |> CostTracker.add_reported_usage(nil, usage)
      |> CostTracker.add_reported_usage(nil, usage)

    assert_in_delta tracker.reported.cost_cents, 3_200.0, 0.01
  end

  test "image tokens are attributed to the screen feed as well as the call" do
    tracker =
      []
      |> Config.normalize()
      |> CostTracker.new()
      |> CostTracker.add_reported_usage("resp_1", %{
        "input_token_details" => %{"image_tokens" => 1_000_000, "audio_tokens" => 1_000_000}
      })

    # image in (1M * $5/M) = $5 = 500 cents, and the feed line carries only that
    assert tracker.feed.image_tokens == 1_000_000
    assert_in_delta tracker.feed.cost_cents, 500.0, 0.01
    # the call total also includes the audio: $5 + $32 = $37 = 3_700 cents
    assert_in_delta tracker.reported.cost_cents, 3_700.0, 0.01
  end

  test "the feed stops at its share of the call budget, before the call does" do
    config = Config.normalize(max_estimated_cost_cents_per_session: 100)

    # 100k image tokens at $5/1M = $0.50 = 50 cents = half of a 100-cent budget
    tracker =
      config
      |> CostTracker.new()
      |> CostTracker.add_reported_usage("resp_1", %{
        "input_token_details" => %{"image_tokens" => 100_000}
      })

    assert CostTracker.feed_over_budget?(tracker)
    # ...and the CALL itself is still under its cap, so the voice session survives.
    assert :ok = CostTracker.enforce_limits(tracker)
  end

  test "a model with no rates cannot ship" do
    for model <- Config.valid_models() do
      assert Map.has_key?(CostTracker.rates(), model),
             "realtime model #{model} has no CostTracker rates — add them (Open Issue #8)"
    end
  end

  test "rates are priced per model, not shared" do
    mini =
      [model: "gpt-realtime-2.1-mini"]
      |> Config.normalize()
      |> CostTracker.new()
      |> CostTracker.add_reported_usage("resp_1", %{
        "input_token_details" => %{"image_tokens" => 1_000_000}
      })

    # mini bills images at $0.80/1M, not the flagship $5/1M
    assert_in_delta mini.feed.cost_cents, 80.0, 0.01
  end
end
