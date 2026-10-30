defmodule FermixCore.Home.Snapshot.TelemetryTest do
  # async: false: the trace handler attaches to the VM-wide telemetry table.
  use ExUnit.Case, async: false

  alias FermixCore.Home.Snapshot.Telemetry
  alias FermixCore.Trace
  alias FermixCore.Trace.TelemetryHandler
  alias FermixTestSupport.SafeRm

  setup do
    dir = SafeRm.make_tmp_dir!("snapshot_telemetry")
    name = :"snapshot_trace_#{System.unique_integer([:positive])}"
    start_supervised!({Trace, base_dir: dir, name: name})
    prefix = "snapshot-test-#{System.unique_integer([:positive])}"
    TelemetryHandler.attach(trace_server: name, handler_prefix: prefix)

    on_exit(fn ->
      TelemetryHandler.detach(prefix)
      SafeRm.rm_rf!(dir)
    end)

    %{dir: dir, server: name}
  end

  test "a run's outcome per target is one home_snapshot row, with no reason riding",
       %{dir: dir, server: server} do
    started = System.monotonic_time(:millisecond)
    epoch = System.unique_integer([:positive])

    :ok = Telemetry.emit("s3", :verified, %{size: 4_096, epoch: epoch}, started)

    :ok =
      Telemetry.emit(
        "s3",
        {:failed, {:refused, 403, "AccessDenied", "Access Denied"}},
        %{size: 4_096, epoch: epoch},
        started
      )

    :ok =
      Telemetry.emit(
        "desktop",
        {:waiting, {:not_connected, "Studio Mac"}},
        %{size: 4_096, epoch: epoch},
        started
      )

    :sys.get_state(server)

    rows =
      [dir, Date.to_iso8601(Date.utc_today()), "agent_event.jsonl"]
      |> Path.join()
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["event"] == "home_snapshot" and &1["epoch"] == epoch))

    assert [verified, failed, waiting] = rows
    assert verified["agent"] == "s3"
    assert verified["result"] == "verified"
    assert verified["bytes"] == 4_096
    assert failed["result"] == "failed"
    assert failed["error_class"] == "refused"
    refute inspect(failed) =~ "Access Denied"
    assert waiting["agent"] == "desktop"
    assert waiting["result"] == "waiting"
    assert waiting["error_class"] == "not_connected"
    refute inspect(waiting) =~ "Studio Mac"
  end
end
