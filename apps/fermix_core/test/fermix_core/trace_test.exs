defmodule FermixCore.TraceTest do
  use ExUnit.Case, async: true

  alias FermixCore.Trace

  @valid_types [:llm_call, :tool_exec, :agent_event, :channel_msg, :error, :sandbox_event]

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "fermix_trace_#{System.unique_integer([:positive])}")
    name = :"trace_test_#{System.unique_integer([:positive])}"
    start_supervised!({Trace, base_dir: tmp_dir, name: name})

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_dir) end)

    %{dir: tmp_dir, server: name}
  end

  defp sync(server), do: :sys.get_state(server)

  defp today_dir(base_dir) do
    Path.join(base_dir, Date.utc_today() |> Date.to_iso8601())
  end

  defp read_entries(base_dir, type) do
    Path.join(today_dir(base_dir), "#{type}.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  test "writes JSONL entry to date-partitioned file", %{dir: dir, server: server} do
    Trace.record(:llm_call, "main", %{provider: "openai"}, server: server)
    sync(server)

    entries = read_entries(dir, :llm_call)
    assert length(entries) == 1

    [entry] = entries
    assert entry["type"] == "llm_call"
    assert entry["agent"] == "main"
    assert entry["provider"] == "openai"
  end

  test "includes ISO8601 timestamp in entry", %{dir: dir, server: server} do
    Trace.record(:tool_exec, "main", %{tool: "shell"}, server: server)
    sync(server)

    [entry] = read_entries(dir, :tool_exec)
    assert {:ok, _dt, _offset} = DateTime.from_iso8601(entry["ts"])
  end

  test "each trace type writes to its own file", %{dir: dir, server: server} do
    for type <- @valid_types do
      Trace.record(type, "test", %{}, server: server)
    end

    sync(server)

    for type <- @valid_types do
      path = Path.join(today_dir(dir), "#{type}.jsonl")
      assert File.exists?(path), "Expected #{type}.jsonl to exist"
    end
  end

  test "multiple records append to the same file", %{dir: dir, server: server} do
    Trace.record(:llm_call, "a1", %{n: 1}, server: server)
    Trace.record(:llm_call, "a2", %{n: 2}, server: server)
    Trace.record(:llm_call, "a3", %{n: 3}, server: server)
    sync(server)

    entries = read_entries(dir, :llm_call)
    assert length(entries) == 3
    assert Enum.map(entries, & &1["agent"]) == ["a1", "a2", "a3"]
  end

  test "accepts atom agent names", %{dir: dir, server: server} do
    Trace.record(:agent_event, :main, %{event: "started"}, server: server)
    sync(server)

    [entry] = read_entries(dir, :agent_event)
    assert entry["agent"] == "main"
  end

  test "includes all data fields in entry", %{dir: dir, server: server} do
    data = %{provider: "anthropic", model: "claude-3", tokens_in: 500, tokens_out: 200}
    Trace.record(:llm_call, "main", data, server: server)
    sync(server)

    [entry] = read_entries(dir, :llm_call)
    assert entry["provider"] == "anthropic"
    assert entry["model"] == "claude-3"
    assert entry["tokens_in"] == 500
    assert entry["tokens_out"] == 200
  end

  test "scrubs invalid UTF-8 in a value and records it instead of crashing", %{
    dir: dir,
    server: server
  } do
    # A tool output carrying a non-UTF-8 byte (e.g. a Latin-1 source file) must
    # not raise Jason.EncodeError inside the Trace GenServer — Trace is a
    # rest_for_one ancestor of the agent and job supervisors, so a crash here
    # cascade-restarts them. The bad bytes are scrubbed and the entry recorded.
    poisoned = "before " <> <<0xF3>> <> " after"
    Trace.record(:tool_exec, "main", %{output: poisoned}, server: server)
    sync(server)

    [entry] = read_entries(dir, :tool_exec)
    assert entry["output"] =~ "before"
    assert entry["output"] =~ "after"
  end

  test "drops a non-encodable value without crashing Trace", %{dir: dir, server: server} do
    # A PID has no Jason.Encoder, so encoding raises Protocol.UndefinedError /
    # UndefinedFunctionError — NOT Jason.EncodeError. Scrubbing can't fix it, so
    # the entry is dropped, but Trace (a rest_for_one cascade root) must keep
    # running and continue recording subsequent entries on the same process.
    pid = Process.whereis(server)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Trace.record(:tool_exec, "main", %{handle: self()}, server: server)
        Trace.record(:tool_exec, "main", %{ok: true}, server: server)
        sync(server)
      end)

    assert Process.whereis(server) == pid,
           "Trace crashed — it must never bring down its supervisees"

    assert log =~ "Trace dropped"
    assert [%{"ok" => true}] = read_entries(dir, :tool_exec)
  end

  test "rejects invalid trace types" do
    assert_raise FunctionClauseError, fn ->
      Trace.record(:invalid_type, "main", %{})
    end
  end

  test "rejects non-map data" do
    assert_raise FunctionClauseError, fn ->
      Trace.record(:llm_call, "main", "not a map")
    end
  end
end
