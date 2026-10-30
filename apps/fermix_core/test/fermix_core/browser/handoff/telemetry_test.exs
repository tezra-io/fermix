defmodule FermixCore.Browser.Handoff.TelemetryTest do
  # async: false: the trace handler attaches to the VM-wide telemetry table.
  use ExUnit.Case, async: false

  alias FermixCore.Browser.Handoff.Telemetry
  alias FermixCore.Trace
  alias FermixCore.Trace.TelemetryHandler
  alias FermixTestSupport.SafeRm

  setup do
    dir = SafeRm.make_tmp_dir!("handoff_telemetry")
    name = :"handoff_trace_#{System.unique_integer([:positive])}"
    start_supervised!({Trace, base_dir: dir, name: name})
    prefix = "handoff-test-#{System.unique_integer([:positive])}"
    TelemetryHandler.attach(trace_server: name, handler_prefix: prefix)

    on_exit(fn ->
      TelemetryHandler.detach(prefix)
      SafeRm.rm_rf!(dir)
    end)

    %{dir: dir, server: name}
  end

  test "each hand-off operation is one browser_handoff row, counts only", %{
    dir: dir,
    server: server
  } do
    started = System.monotonic_time(:millisecond)
    # The cookie count pins this test's rows among any other test's.
    cookies = 1_000_000 + System.unique_integer([:positive])

    :ok = Telemetry.emit(:stored, :ok, %{sites: 2, cookies: cookies}, started)

    :ok =
      Telemetry.emit(
        :wiped,
        {:failed, {:devtools_failed, "SECRET-COOKIE-VALUE"}},
        %{sites: 1, cookies: cookies},
        started
      )

    :sys.get_state(server)

    rows =
      [dir, Date.to_iso8601(Date.utc_today()), "agent_event.jsonl"]
      |> Path.join()
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["event"] == "browser_handoff" and &1["cookies"] == cookies))

    assert [stored, wiped] = rows
    assert stored["agent"] == "stored"
    assert stored["result"] == "ok"
    assert stored["sites"] == 2
    assert wiped["agent"] == "wiped"
    assert wiped["error_class"] == "devtools_failed"
    refute inspect(wiped) =~ "SECRET-COOKIE-VALUE"
  end
end
