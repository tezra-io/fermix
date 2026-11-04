defmodule FermixCore.Cues.TelemetryTraceTest do
  # Global posture: the content switch is app env and the trace handler binds a
  # VM-global telemetry handler, so this module runs alone.
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Cues.Pins
  alias FermixCore.Cues.Telemetry
  alias FermixCore.Trace
  alias FermixCore.Trace.TelemetryHandler
  alias FermixTestSupport.MandateFixtures, as: F

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

  # The trace file is written whether or not content is captured, and its rows
  # are what `fermix_opik` replays, so a refused mandate call's row names the
  # pinned argument and never the value the mandate pins.
  test "a refused mandate call's trace row carries no value the mandate pins", %{prior: prior} do
    capture_content(prior, false)
    dir = Path.join(System.tmp_dir!(), "fermix_pin_trace_#{System.unique_integer([:positive])}")
    server = :"pin_trace_#{System.unique_integer([:positive])}"
    prefix = "pin-test-#{System.unique_integer([:positive])}"
    start_supervised!({Trace, base_dir: dir, name: server})
    TelemetryHandler.attach(trace_server: server, handler_prefix: prefix)

    on_exit(fn ->
      TelemetryHandler.detach(prefix)
      FermixTestSupport.SafeRm.rm_rf!(dir)
    end)

    pinned = "quill-harbor-5308@example.invalid"
    fixture = F.cue_run("trace_pin_value")
    config = F.config("release-issues", fixture.job.id, %{"pin_args" => %{"owner" => pinned}})
    context = F.context(fixture, "release-issues", config: config)

    assert {:ok, %{state: :approved}} =
             Pins.approve("release-issues", "test", F.now(), context.cue_mandate_opts)

    args = %{"owner" => "other-org", "repo" => "ops", "title" => "Phoenix 2.0"}

    assert {:ok, %{success: false, error: error}} =
             Capability.execute(F.capability(), args, context)

    assert error =~ pinned
    :sys.get_state(server)

    assert [row] =
             [dir, "**", "tool_exec.jsonl"]
             |> Path.join()
             |> Path.wildcard()
             |> Enum.flat_map(&(&1 |> File.read!() |> String.split("\n", trim: true)))
             |> Enum.map(&Jason.decode!/1)
             |> Enum.filter(&(&1["session_id"] == fixture.run.session_id))

    assert row["access_gate"] == "mandate_refused"
    assert row["mandate_reason"] == "the argument owner differs from what the mandate pins"
    refute Jason.encode!(row) =~ pinned
  end
end
