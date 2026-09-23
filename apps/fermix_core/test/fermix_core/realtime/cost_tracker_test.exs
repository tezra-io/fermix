defmodule FermixCore.Realtime.CostTrackerTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.CostTracker

  # Every priced line in `split_costs/2` resolves one of these through
  # `Map.fetch!/2`, so a model missing any one of them raises mid-call.
  @rate_keys ~w(audio_in text_in image_in cached_audio_in cached_text_in cached_image_in audio_out text_out)a

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
    # text out (1M * $24/M) = $24
    # total = $108.20 = 10_820.0 cents
    assert_in_delta tracker.reported.cost_cents, 10_820.0, 0.01
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

    # 3 x 1M text-out tokens at $24/1M = $72 = 7_200 cents
    assert_in_delta tracker.reported.cost_cents, 7_200.0, 0.01
  end

  test "the same response id is never billed twice" do
    usage = %{"output_token_details" => %{"text_tokens" => 1_000_000}}

    tracker =
      []
      |> Config.normalize()
      |> CostTracker.new()
      |> CostTracker.add_reported_usage("resp_1", usage)
      |> CostTracker.add_reported_usage("resp_1", usage)

    assert_in_delta tracker.reported.cost_cents, 2_400.0, 0.01
  end

  test "a response with no id is still counted (under-reporting spend is worse)" do
    usage = %{"output_token_details" => %{"text_tokens" => 1_000_000}}

    tracker =
      []
      |> Config.normalize()
      |> CostTracker.new()
      |> CostTracker.add_reported_usage(nil, usage)
      |> CostTracker.add_reported_usage(nil, usage)

    assert_in_delta tracker.reported.cost_cents, 4_800.0, 0.01
  end

  # The provider's reported image tokens are dominated by the model's own
  # high-detail tool screenshots, so attributing them to the feed charged the
  # model's precision looks to the feed's budget and closed its ambient eyes as
  # ":cost" for spend that was not the feed's. Reported image spend bills the
  # CALL only; the feed's line is counted per sent frame.
  test "reported image tokens bill the call, never the feed" do
    tracker =
      []
      |> Config.normalize()
      |> CostTracker.new()
      |> CostTracker.add_reported_usage("resp_1", %{
        "input_token_details" => %{"image_tokens" => 1_000_000, "audio_tokens" => 1_000_000}
      })

    assert tracker.feed.image_tokens == 0
    assert tracker.feed.cost_cents == 0.0
    # the call total includes both: $5 (image) + $32 (audio) = 3_700 cents
    assert_in_delta tracker.reported.cost_cents, 3_700.0, 0.01
  end

  test "each sent feed frame grows the feed line at the model's image rate" do
    tracker =
      []
      |> Config.normalize()
      |> CostTracker.new()
      |> CostTracker.add_feed_frame()
      |> CostTracker.add_feed_frame()

    assert tracker.feed.image_tokens > 0
    assert tracker.feed.cost_cents > 0.0
    # two frames cost exactly twice one frame — a fixed per-frame estimate
    one = CostTracker.add_feed_frame(CostTracker.new(Config.normalize([])))
    assert_in_delta tracker.feed.cost_cents, one.feed.cost_cents * 2, 1.0e-9
  end

  test "the feed stops at its share of the call budget, before the call does" do
    # A tiny budget so a realistic number of frames crosses the feed's share
    # while the call total stays under its own cap.
    config = Config.normalize(max_estimated_cost_cents_per_session: 1)

    tracker =
      Enum.reduce(1..12, CostTracker.new(config), fn _n, tracker ->
        CostTracker.add_feed_frame(tracker)
      end)

    assert CostTracker.feed_over_budget?(tracker)
    # ...and the CALL itself is still under its cap, so the voice session survives.
    assert :ok = CostTracker.enforce_limits(tracker)
  end

  test "a model with no rates cannot ship" do
    for model <- Config.valid_models() do
      rates = Map.get(CostTracker.rates(), model)

      assert rates,
             "realtime model #{model} has no CostTracker rates — add them (Open Issue #8)"

      for key <- @rate_keys do
        assert Map.has_key?(rates, key),
               "realtime model #{model} has no #{key} rate — every priced line must resolve"
      end
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
    assert_in_delta mini.reported.cost_cents, 80.0, 0.01

    # ...and its cached rates diverge per modality, which a shared table hid.
    assert CostTracker.rates()["gpt-realtime-2.1-mini"].cached_text_in == 0.06
    assert CostTracker.rates()["gpt-realtime-2.1"].cached_text_in == 0.40
  end

  # `gpt-realtime-2` and `gpt-realtime-2.1` publish the SAME text-output rate;
  # pricing 2 at $16/M under-reported every text response on the default model.
  test "gpt-realtime-2 prices text output at the published $24/M rate" do
    tracker =
      [model: "gpt-realtime-2"]
      |> Config.normalize()
      |> CostTracker.new()
      |> CostTracker.add_reported_usage("resp_1", %{
        "output_token_details" => %{"text_tokens" => 1_000_000}
      })

    assert CostTracker.rates()["gpt-realtime-2"].text_out == 24.0
    assert_in_delta tracker.reported.cost_cents, 2_400.0, 0.01
  end

  # One cached rate per model billed a cached IMAGE token at the audio rate. The
  # breakdown the payload already carries is the only honest split.
  test "cached audio, text and image are each billed at their own rate" do
    usage = %{
      "input_token_details" => %{
        "audio_tokens" => 1_000_000,
        "text_tokens" => 1_000_000,
        "image_tokens" => 1_000_000,
        "cached_tokens" => 3_000_000,
        "cached_tokens_details" => %{
          "audio_tokens" => 1_000_000,
          "text_tokens" => 1_000_000,
          "image_tokens" => 1_000_000
        }
      }
    }

    flagship =
      [] |> Config.normalize() |> CostTracker.new() |> CostTracker.add_reported_usage("r1", usage)

    mini =
      [model: "gpt-realtime-2.1-mini"]
      |> Config.normalize()
      |> CostTracker.new()
      |> CostTracker.add_reported_usage("r1", usage)

    # every input token is cached, so nothing bills at an uncached rate:
    # flagship $0.40 + $0.40 + $0.50 = $1.30; mini $0.30 + $0.06 + $0.08 = $0.44
    assert_in_delta flagship.reported.cost_cents, 130.0, 0.01
    assert_in_delta mini.reported.cost_cents, 44.0, 0.01
  end

  # The spread path (no `cached_tokens_details`) is an approximation of WHICH
  # modality cached, never an extra line: the same token must not be billed at
  # both its full and its cached rate. That double-bill tore a live call down.
  test "the spread path bills cached tokens once, never twice" do
    tracker =
      []
      |> Config.normalize()
      |> CostTracker.new()
      |> CostTracker.add_reported_usage("resp_1", %{
        "input_token_details" => %{
          "audio_tokens" => 1_000_000,
          "text_tokens" => 200_000,
          "cached_tokens" => 1_200_000
        }
      })

    # all 1.2M input tokens are cached: 1M audio at $0.40/M + 200k text at
    # $0.40/M = $0.48. A double-bill would add $32 of audio and $0.80 of text.
    assert_in_delta tracker.reported.cost_cents, 48.0, 0.01
  end

  # Input transcription is a real, separately invoiced line that the estimate
  # ignored entirely, so no total here could be compared against an invoice.
  test "transcription minutes accrue and count toward the ceiling" do
    tracker =
      [max_estimated_cost_cents_per_session: 5]
      |> Config.normalize()
      |> CostTracker.new()
      |> CostTracker.add_transcription_ms(10 * 60_000)

    # whisper-1 at $0.006/min: ten minutes = 6 cents, over a 5-cent ceiling
    assert tracker.estimated.transcription_ms == 600_000
    assert_in_delta tracker.estimated.transcription_cost_cents, 6.0, 0.001
    assert {:stop, :cost_limit} = CostTracker.enforce_limits(tracker)
  end

  test "the transcription line adds to the audio estimate rather than replacing it" do
    tracker =
      []
      |> Config.normalize()
      |> CostTracker.new()
      |> CostTracker.add_transcription_ms(60_000)
      |> CostTracker.add_input_audio_ms(60_000)
      |> CostTracker.add_transcription_ms(60_000)

    assert tracker.estimated.input_audio_ms == 60_000
    assert tracker.estimated.input_audio_tokens == 600
    assert tracker.estimated.transcription_ms == 120_000
    assert_in_delta tracker.estimated.transcription_cost_cents, 1.2, 0.001
  end
end
