defmodule FermixCore.Realtime.GrokLatencyTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.GrokLatency

  test "a turn's reply is timed to its first generated and first played audio, apart" do
    latency =
      GrokLatency.new()
      |> GrokLatency.speech_ended(1_000)
      |> GrokLatency.audio_forwarded(1_400)
      |> GrokLatency.audio_forwarded(1_500)
      |> GrokLatency.audio_played(1_650)
      |> GrokLatency.audio_played(1_800)

    assert GrokLatency.measurements(latency) == %{
             user_turns: 1,
             generation_latency_ms_median: 400,
             generation_latency_ms_max: 400,
             audible_latency_ms_median: 650,
             audible_latency_ms_max: 650
           }
  end

  test "audio no speech started (a continuation) is not a turn's reply" do
    latency =
      GrokLatency.new()
      |> GrokLatency.audio_forwarded(500)
      |> GrokLatency.audio_played(600)

    assert GrokLatency.measurements(latency) == %{user_turns: 0}
  end

  test "a turn with no reply yet leaves its latencies unknown, never zero" do
    latency = GrokLatency.speech_ended(GrokLatency.new(), 1_000)
    assert GrokLatency.measurements(latency) == %{user_turns: 1}
  end

  test "the median and the maximum over several turns" do
    latency =
      Enum.reduce([300, 900, 500], GrokLatency.new(), fn wait, acc ->
        acc |> GrokLatency.speech_ended(0) |> GrokLatency.audio_forwarded(wait)
      end)

    assert %{user_turns: 3, generation_latency_ms_median: 500, generation_latency_ms_max: 900} =
             GrokLatency.measurements(latency)
  end
end
