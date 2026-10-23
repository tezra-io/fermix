defmodule FermixCore.Cues.TelemetryTraceTest do
  # Global posture: the content switch is app env and the trace handler binds a
  # VM-global telemetry handler, so this module runs alone.
  use ExUnit.Case, async: false

  alias FermixCore.Cues.Telemetry
  alias FermixCore.Trace
  alias FermixCore.Trace.TelemetryHandler

  setup do
    prior = Application.get_env(:fermix_core, :telemetry, [])
    on_exit(fn -> Application.put_env(:fermix_core, :telemetry, prior) end)
    %{prior: prior}
  end

  defp capture_content(prior, enabled?) do
    Application.put_env(:fermix_core, :telemetry, Keyword.put(prior, :capture_content, enabled?))
  end

  test "content rides only behind the content gate", %{prior: prior} do
    FermixTestSupport.TelemetryCapture.attach([[:fermix, :cue, :lifecycle]], :emitter)

    capture_content(prior, false)
    Telemetry.lifecycle(:accepted, %{}, %{source_ref: "s", content: "Disk almost full"})
    assert_receive {:telemetry, _event, _m, closed}
    refute Map.has_key?(closed, :content)

    capture_content(prior, true)
    Telemetry.lifecycle(:accepted, %{}, %{source_ref: "s", content: "Disk almost full"})
    assert_receive {:telemetry, _event, _m, %{content: "Disk almost full"}}
  end

  test "lifecycle and source events reach the JSONL trace stream", %{prior: prior} do
    capture_content(prior, false)
    dir = Path.join(System.tmp_dir!(), "fermix_cue_trace_#{System.unique_integer([:positive])}")
    server = :"cue_trace_#{System.unique_integer([:positive])}"
    prefix = "cue-test-#{System.unique_integer([:positive])}"
    start_supervised!({Trace, base_dir: dir, name: server})
    TelemetryHandler.attach(trace_server: server, handler_prefix: prefix)

    on_exit(fn ->
      TelemetryHandler.detach(prefix)
      FermixTestSupport.SafeRm.rm_rf!(dir)
    end)

    ref = "trace-#{System.unique_integer([:positive])}"
    Telemetry.lifecycle(:accepted, %{accept_ms: 3}, %{source_ref: ref, cue_id: 1})
    Telemetry.source(:connect, %{source_ref: ref, status: "connected"})
    :sys.get_state(server)

    rows =
      [dir, Date.utc_today() |> Date.to_iso8601(), "agent_event.jsonl"]
      |> Path.join()
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["source_ref"] == ref))

    assert Enum.map(rows, & &1["event"]) == ["cue_lifecycle", "cue_source"]
    assert Enum.all?(rows, &(&1["agent"] == "cues"))
    assert [%{"phase" => "accepted", "accept_ms" => 3, "cue_id" => 1}, _source] = rows
  end
end
