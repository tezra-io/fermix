defmodule FermixOpik.ComputerCallTest do
  @moduledoc """
  A voice call from a linked computer (M97 §9.2) is the phone call's run
  type with the endpoint `computer:<device_id>`: its root names the endpoint,
  and a link that drops and comes back is the call's detach and resume, as a
  phone's are.
  """

  use ExUnit.Case, async: true

  alias FermixOpik.Aggregation

  @start [:fermix, :voice_live, :call_start]
  @stop [:fermix, :voice_live, :call_stop]
  @call "voice_live:7"
  @computer "computer:6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"

  test "a computer's call is a live call whose root and gaps name the computer" do
    computer = %{endpoint: @computer}

    {_state, closed} =
      run([
        {@start, %{}, meta(Map.put(computer, :max_duration_ms, 900_000))},
        {[:fermix, :voice_live, :phone_detached], %{}, meta(computer)},
        {[:fermix, :voice_live, :phone_resumed], %{duration_ms: 800}, meta(computer)},
        {@stop, %{voice_seconds: 30.0}, meta(%{reason: "call_stop"})}
      ])

    assert [%{trace: trace, spans: spans}] = closed
    assert trace.metadata.endpoint == @computer
    resumed = Enum.find(spans, &(&1.name == "voice_live:phone_resumed"))
    assert resumed.metadata.endpoint == @computer
  end

  defp run(events) do
    agg = Aggregation.new(project: "fermix", ttl_ms: 120_000)
    base = ~U[2026-11-14 12:00:00.000Z]

    events
    |> Enum.with_index()
    |> Enum.reduce({agg, []}, fn {{event, meas, meta}, i}, {state, acc} ->
      at = %{at: DateTime.add(base, i, :second), mono: i * 1_000_000}
      {state, new} = Aggregation.apply_event(state, event, meas, meta, at)
      {state, acc ++ new}
    end)
  end

  defp meta(extra) do
    Map.merge(
      %{
        agent: "voice_live",
        session_id: @call,
        device_id: "dev-1",
        model: "gpt-live-1",
        voice: "marin",
        engine: "openai_live",
        provider: "openai"
      },
      extra
    )
  end
end
