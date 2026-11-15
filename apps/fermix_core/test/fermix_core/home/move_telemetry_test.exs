defmodule FermixCore.Home.MoveTelemetryTest do
  # async: false: the trace handler attaches to the VM-wide telemetry table.
  use ExUnit.Case, async: false

  alias FermixCore.Home.MoveTelemetry
  alias FermixCore.Trace
  alias FermixCore.Trace.TelemetryHandler
  alias FermixTestSupport.SafeRm

  setup do
    dir = SafeRm.make_tmp_dir!("move_telemetry")
    name = :"move_trace_#{System.unique_integer([:positive])}"
    start_supervised!({Trace, base_dir: dir, name: name})
    prefix = "move-test-#{System.unique_integer([:positive])}"
    TelemetryHandler.attach(trace_server: name, handler_prefix: prefix)

    on_exit(fn ->
      TelemetryHandler.detach(prefix)
      SafeRm.rm_rf!(dir)
    end)

    %{dir: dir, server: name}
  end

  test "each side's bookends are home_move rows keyed on the side, with no reason riding",
       %{dir: dir, server: server} do
    move_id = "mv-#{System.unique_integer([:positive])}"

    started = MoveTelemetry.started(:source, move_id, 4)
    :ok = MoveTelemetry.finished(:source, move_id, 5, :done, started)
    candidate = MoveTelemetry.started(:candidate, move_id, 4)

    :ok =
      MoveTelemetry.finished(
        :candidate,
        move_id,
        nil,
        {:failed, {:restore, "a vendor's secret words"}},
        candidate
      )

    :sys.get_state(server)

    rows =
      [dir, Date.to_iso8601(Date.utc_today()), "agent_event.jsonl"]
      |> Path.join()
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["event"] == "home_move" and &1["move_id"] == move_id))

    assert [source_start, source_end, candidate_start, candidate_end] = rows
    assert source_start["agent"] == "source"
    assert source_start["phase"] == "started"
    assert source_end["result"] == "done"
    assert source_end["epoch"] == 5
    assert candidate_start["agent"] == "candidate"
    assert candidate_end["result"] == "failed"
    assert candidate_end["error_class"] == "restore"
    refute inspect(rows) =~ "secret words"
  end

  # EC2 test 2026-11-08: a move logged only its start and its end, so nothing
  # told transfer from archiving. Each phase of each side now logs one info
  # line: how it ended, its start and end by the wall clock, how long it
  # took, and the bytes it captured, sent or received.
  describe "a phase's line" do
    setup do
      Logger.put_module_level(MoveTelemetry, :info)
      on_exit(fn -> Logger.delete_module_level(MoveTelemetry) end)

      {:ok, clock} =
        Agent.start_link(fn -> [~U[2031-05-04 10:00:00Z], ~U[2031-05-04 10:00:12Z]] end)

      %{clock: fn -> Agent.get_and_update(clock, fn [now | later] -> {now, later} end) end}
    end

    test "names the side, the phase, its times and its bytes", %{clock: clock} do
      phase = MoveTelemetry.phase(:source, "capture", "mv-91", clock)

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          :ok = MoveTelemetry.phase_ended(phase, :done, {"captured", 1_048_576})
        end)

      assert log =~
               ~r/\[info\] move mv-91 source: capture done, 2031-05-04T10:00:00Z to 2031-05-04T10:00:12Z \(\d+\.\d s\), 1048576 bytes captured\n/
    end

    test "a phase that moved no bytes, or failed, says so", %{clock: clock} do
      phase = MoveTelemetry.phase(:candidate, "staging", "mv-92", clock)

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          :ok = MoveTelemetry.phase_ended(phase, :failed, nil)
        end)

      assert log =~
               ~r/move mv-92 candidate: staging failed, 2031-05-04T10:00:00Z to 2031-05-04T10:00:12Z \(\d+\.\d s\)\n/
    end
  end
end
