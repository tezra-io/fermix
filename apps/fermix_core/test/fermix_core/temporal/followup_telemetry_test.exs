defmodule FermixCore.Temporal.FollowupTelemetryTest do
  # async: false — the content gate is `Application` env and the trace-registration
  # test attaches the real `Trace.TelemetryHandler`. Both preconditions are
  # established in this file's own setup and restored on exit.
  use ExUnit.Case, async: false

  alias FermixCore.Temporal.FollowupTelemetry
  alias FermixCore.Trace
  alias FermixCore.Trace.TelemetryHandler

  @start_event [:fermix, :reminder, :followup_start]
  @complete_event [:fermix, :reminder, :followup_complete]
  @error_event [:fermix, :reminder, :followup_error]

  # A follow-up IS a run kind (§22.2): exactly three bookends, no more.
  @events [@start_event, @complete_event, @error_event]

  @row %{
    id: "rem_1",
    event_id: "evt_1",
    occurrence_key: "2026-09-14",
    delivery_platform: "telegram"
  }

  setup do
    handler = "temporal-followup-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler,
      @events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:followup, List.last(event), measurements, metadata})
      end,
      nil
    )

    prior = Application.get_env(:fermix_core, :telemetry, [])
    Application.put_env(:fermix_core, :telemetry, Keyword.put(prior, :capture_content, false))

    on_exit(fn ->
      :telemetry.detach(handler)
      Application.put_env(:fermix_core, :telemetry, prior)
    end)

    %{run: FollowupTelemetry.correlation(@row)}
  end

  defp capture_content(enabled?) do
    prior = Application.get_env(:fermix_core, :telemetry, [])
    Application.put_env(:fermix_core, :telemetry, Keyword.put(prior, :capture_content, enabled?))
  end

  describe "correlation/1" do
    test "derives one identity the loop context and the trace both read" do
      assert FollowupTelemetry.correlation(@row) == %{
               session_id: "followup_rem_1",
               agent: "followup:evt_1",
               event_id: "evt_1",
               reminder_id: "rem_1",
               occurrence_key: "2026-09-14"
             }
    end
  end

  describe "the three bookends" do
    test "run_start carries the run's identity and its sweep floor", %{run: run} do
      FollowupTelemetry.run_start(run, 120_000)

      assert_receive {:followup, :followup_start, _measurements, metadata}
      assert metadata.session_id == "followup_rem_1"
      assert metadata.agent == "followup:evt_1"
      assert metadata.event_id == "evt_1"
      assert metadata.reminder_id == "rem_1"
      assert metadata.occurrence_key == "2026-09-14"
      assert metadata.component == "temporal_followup"
      assert metadata.max_duration_ms == 120_000
      refute Map.has_key?(metadata, :outcome)
    end

    test "run_complete carries the outcome and the run duration", %{run: run} do
      FollowupTelemetry.run_complete(run, "declined", 1_234)

      assert_receive {:followup, :followup_complete, measurements, metadata}
      assert measurements.duration_ms == 1_234
      assert metadata.outcome == "declined"
      assert metadata.session_id == "followup_rem_1"
      assert metadata.component == "temporal_followup"
    end

    test "run_error names which failure closed the run", %{run: run} do
      FollowupTelemetry.run_error(run, "timeout", 120_000, "wall-clock timeout after 120000ms")

      assert_receive {:followup, :followup_error, measurements, metadata}
      assert measurements.duration_ms == 120_000
      assert metadata.status == "timeout"
      assert metadata.error =~ "wall-clock timeout"
      assert metadata.session_id == "followup_rem_1"
    end
  end

  describe "the content gate" do
    test "the sent message is dropped while the shared gate is off", %{run: run} do
      FollowupTelemetry.run_complete(run, "sent", 10, "Want me to help you pick something out?")

      assert_receive {:followup, :followup_complete, _measurements, metadata}
      refute Map.has_key?(metadata, :output)
    end

    test "the sent message rides only when the operator opted in", %{run: run} do
      capture_content(true)

      FollowupTelemetry.run_complete(run, "sent", 10, "Want me to help you pick something out?")

      assert_receive {:followup, :followup_complete, _measurements, metadata}
      assert metadata.output == "Want me to help you pick something out?"
    end
  end

  describe "trace registration" do
    test "every definition names an agent_field the emitter actually sets", %{run: run} do
      definitions = FollowupTelemetry.trace_event_definitions()

      assert Enum.map(definitions, & &1.event) == @events

      for definition <- definitions do
        assert definition.trace_type == :agent_event
        assert definition.agent_field == :agent
      end

      FollowupTelemetry.run_start(run, 120_000)
      assert_receive {:followup, :followup_start, _measurements, metadata}
      assert Map.has_key?(metadata, :agent)
    end

    test "the shared handler writes a follow-up bookend as an agent_event row", %{run: run} do
      dir =
        Path.join(
          System.tmp_dir!(),
          "fermix_followup_trace_#{System.unique_integer([:positive])}"
        )

      server = :"followup_trace_#{System.unique_integer([:positive])}"
      prefix = "followup-test-#{System.unique_integer([:positive])}"

      start_supervised!({Trace, base_dir: dir, name: server})
      TelemetryHandler.attach(trace_server: server, handler_prefix: prefix)

      on_exit(fn ->
        TelemetryHandler.detach(prefix)
        FermixTestSupport.SafeRm.rm_rf!(dir)
      end)

      FollowupTelemetry.run_complete(run, "sent", 42)

      :sys.get_state(server)

      entry =
        [dir, Date.to_iso8601(Date.utc_today()), "agent_event.jsonl"]
        |> Path.join()
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&(&1["event"] == "reminder_followup_complete"))

      assert entry, "the follow-up bookend is not registered in the trace handler"
      assert entry["agent"] == "followup:evt_1"
      assert entry["outcome"] == "sent"
      assert entry["duration_ms"] == 42
      assert entry["session_id"] == "followup_rem_1"
    end
  end
end
