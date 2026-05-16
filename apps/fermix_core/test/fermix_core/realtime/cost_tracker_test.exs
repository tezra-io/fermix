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
      |> CostTracker.put_reported_tokens(%{
        "output_token_details" => %{"audio_tokens" => 500_000}
      })

    assert {:stop, :cost_limit} = CostTracker.enforce_limits(estimated)
    assert {:stop, :cost_limit} = CostTracker.enforce_limits(reported)
  end

  test "put_reported_tokens prices audio/text input/output and credits cached input" do
    tracker =
      []
      |> Config.normalize()
      |> CostTracker.new()
      |> CostTracker.put_reported_tokens(%{
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

  test "put_reported_tokens treats missing or non-integer fields as zero" do
    tracker =
      []
      |> Config.normalize()
      |> CostTracker.new()
      |> CostTracker.put_reported_tokens(%{})

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
end
