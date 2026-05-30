defmodule FermixCore.Sandbox.DecisionTelemetryTest do
  use ExUnit.Case, async: false

  alias FermixCore.Sandbox.Decision
  alias FermixCore.Sandbox.DecisionTelemetry
  alias FermixCore.Trace

  setup do
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-decision-trace")
    server = :"sandbox_decision_trace_#{System.unique_integer([:positive])}"
    prefix = "sandbox-decision-test-#{System.unique_integer([:positive])}"

    start_supervised!({Trace, base_dir: dir, name: server})
    DecisionTelemetry.attach(trace_server: server, handler_prefix: prefix)

    on_exit(fn ->
      DecisionTelemetry.detach(prefix)
      FermixTestSupport.SafeRm.rm_rf!(dir)
    end)

    %{dir: dir, server: server}
  end

  test "persists deny decisions as sandbox_event rows", %{dir: dir, server: server} do
    Decision.emit({:deny, {:outside_root, "/tmp/project/app.ex"}}, metadata(:file_write))
    sync(server)

    [entry] = read_entries(dir)

    assert entry["type"] == "sandbox_event"
    assert entry["agent"] == "main"
    assert entry["event"] == "sandbox_decision"
    assert entry["decision"] == "deny"
    assert entry["capability"] == "file_write"
    assert entry["policy_class"] == "read_write"
    assert entry["reason_tag"] == "outside_root"
    assert entry["resource"] == "/tmp/project/app.ex"
    assert entry["conversation_key"] == "{\"telegram\", \"123\", :root}"
  end

  test "persists hardline decisions and ignores allow decisions", %{dir: dir, server: server} do
    Decision.emit(:allow, metadata(:shell))
    Decision.emit({:hardline, "recursive delete of a protected root"}, metadata(:shell))
    sync(server)

    [entry] = read_entries(dir)

    assert entry["decision"] == "hardline"
    assert entry["reason_tag"] == "hardline"
    assert entry["resource"] == "recursive delete of a protected root"
  end

  defp metadata(operation) do
    %{
      agent: "main",
      operation: operation,
      policy_class: :read_write,
      conversation_key: {"telegram", "123", :root}
    }
  end

  defp sync(server), do: :sys.get_state(server)

  defp read_entries(dir) do
    path = Path.join([dir, Date.utc_today() |> Date.to_iso8601(), "sandbox_event.jsonl"])

    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
