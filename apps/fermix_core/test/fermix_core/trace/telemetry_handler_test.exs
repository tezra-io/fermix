defmodule FermixCore.Trace.TelemetryHandlerTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.LifecycleTelemetry
  alias FermixCore.Trace
  alias FermixCore.Trace.TelemetryHandler

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "fermix_tel_#{System.unique_integer([:positive])}")
    name = :"tel_trace_#{System.unique_integer([:positive])}"
    start_supervised!({Trace, base_dir: tmp_dir, name: name})

    prefix = "test-#{System.unique_integer([:positive])}"
    TelemetryHandler.attach(trace_server: name, handler_prefix: prefix)

    on_exit(fn ->
      TelemetryHandler.detach(prefix)
      File.rm_rf!(tmp_dir)
    end)

    %{dir: tmp_dir, server: name}
  end

  defp sync(server), do: :sys.get_state(server)

  defp read_entries(base_dir, type) do
    Path.join([base_dir, Date.utc_today() |> Date.to_iso8601(), "#{type}.jsonl"])
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp entries_for_session(entries, session_id) do
    Enum.filter(entries, &(&1["session_id"] == session_id))
  end

  defp find_entry!(entries, matcher) do
    Enum.find(entries, matcher) ||
      flunk("expected matching trace entry, got: #{inspect(entries, pretty: true)}")
  end

  defp assert_entries_in_order(entries, expected_entries) do
    indexes =
      Enum.map(expected_entries, fn entry ->
        Enum.find_index(entries, &(&1 == entry)) ||
          flunk("expected trace entry in ordered list, got: #{inspect(entry, pretty: true)}")
      end)

    assert indexes == Enum.sort(indexes)
    assert length(indexes) == length(Enum.uniq(indexes))
  end

  test "provider:call event creates llm_call trace", %{dir: dir, server: server} do
    :telemetry.execute(
      [:fermix, :provider, :call],
      %{duration_ms: 1500, tokens_in: 100, tokens_out: 50},
      %{agent: "main", provider: "openai", model: "gpt-4"}
    )

    sync(server)

    [entry] = read_entries(dir, :llm_call)
    assert entry["type"] == "llm_call"
    assert entry["agent"] == "main"
    assert entry["provider"] == "openai"
    assert entry["duration_ms"] == 1500
  end

  test "tool:exec event creates tool_exec trace", %{dir: dir, server: server} do
    :telemetry.execute(
      [:fermix, :tool, :exec],
      %{duration_ms: 120},
      %{agent: "main", tool: "shell", success: true}
    )

    sync(server)

    entries = read_entries(dir, :tool_exec)
    entry = Enum.find(entries, &(&1["agent"] == "main" and &1["tool"] == "shell"))
    assert entry["type"] == "tool_exec"
    assert entry["tool"] == "shell"
    assert entry["success"] == true
  end

  test "channel:message event creates channel_msg trace", %{dir: dir, server: server} do
    :telemetry.execute(
      [:fermix, :channel, :message],
      %{},
      %{direction: "inbound", channel: "telegram", sender: "user123"}
    )

    sync(server)

    [entry] = read_entries(dir, :channel_msg)
    assert entry["type"] == "channel_msg"
    assert entry["channel"] == "telegram"
    assert entry["direction"] == "inbound"
  end

  test "telemetry data merges measurements and metadata", %{dir: dir, server: server} do
    :telemetry.execute(
      [:fermix, :provider, :call],
      %{duration_ms: 2000},
      %{agent: "skill_1", provider: "anthropic", model: "claude-4"}
    )

    sync(server)

    [entry] = read_entries(dir, :llm_call)
    assert entry["duration_ms"] == 2000
    assert entry["provider"] == "anthropic"
    assert entry["model"] == "claude-4"
  end

  test "defaults agent to unknown when missing", %{dir: dir, server: server} do
    :telemetry.execute(
      [:fermix, :tool, :exec],
      %{duration_ms: 50},
      %{tool: "http"}
    )

    sync(server)

    entries = read_entries(dir, :tool_exec)
    entry = Enum.find(entries, &(&1["tool"] == "http"))
    assert entry["agent"] == "unknown"
  end

  test "agent lifecycle events create agent_event traces with explicit event names", %{
    dir: dir,
    server: server
  } do
    LifecycleTelemetry.agent_start(
      "coding-skill",
      :skill,
      "skill-session-1",
      parent: "main",
      parent_session: "main-session-1"
    )

    LifecycleTelemetry.agent_task_start(
      "coding-skill",
      :skill,
      "skill-session-1",
      "Read README",
      parent: "main",
      parent_session: "main-session-1"
    )

    LifecycleTelemetry.agent_task_complete(
      "coding-skill",
      :skill,
      "skill-session-1",
      true,
      87,
      2,
      parent: "main",
      parent_session: "main-session-1"
    )

    LifecycleTelemetry.agent_stop(
      "coding-skill",
      :skill,
      "skill-session-1",
      :normal,
      87,
      parent: "main",
      parent_session: "main-session-1"
    )

    sync(server)

    session_entries =
      dir
      |> read_entries(:agent_event)
      |> entries_for_session("skill-session-1")

    start_entry = find_entry!(session_entries, &(&1["event"] == "agent_start"))

    task_start_entry =
      find_entry!(session_entries, fn entry ->
        entry["event"] == "agent_task_start" and entry["task_summary"] == "Read README"
      end)

    task_complete_entry = find_entry!(session_entries, &(&1["event"] == "agent_task_complete"))
    stop_entry = find_entry!(session_entries, &(&1["event"] == "agent_stop"))

    assert_entries_in_order(session_entries, [
      start_entry,
      task_start_entry,
      task_complete_entry,
      stop_entry
    ])

    assert Enum.map(session_entries, & &1["event"]) == [
             "agent_start",
             "agent_task_start",
             "agent_task_complete",
             "agent_stop"
           ]

    assert start_entry["event"] == "agent_start"
    assert start_entry["agent"] == "coding-skill"
    assert start_entry["name"] == "coding-skill"
    assert start_entry["role"] == "skill"
    assert start_entry["session_id"] == "skill-session-1"
    assert start_entry["parent"] == "main"
    assert start_entry["parent_session"] == "main-session-1"

    assert task_start_entry["event"] == "agent_task_start"
    assert task_start_entry["task_summary"] == "Read README"

    assert task_complete_entry["event"] == "agent_task_complete"
    assert task_complete_entry["duration_ms"] == 87
    assert task_complete_entry["iterations"] == 2
    assert task_complete_entry["success"] == true

    assert stop_entry["event"] == "agent_stop"
    assert stop_entry["duration_ms"] == 87
    assert stop_entry["reason"] == "normal"
  end

  test "skill lifecycle events create agent_event traces with skill correlation", %{
    dir: dir,
    server: server
  } do
    LifecycleTelemetry.skill_invoke(
      "coding-skill",
      "skill-session-2",
      "Fix failing test",
      true,
      41,
      "main-session-2",
      parent: "main"
    )

    LifecycleTelemetry.skill_journal_write(
      "coding-skill",
      "skill-session-2",
      "/tmp/fake-journal.md",
      512
    )

    sync(server)

    session_entries =
      dir
      |> read_entries(:agent_event)
      |> entries_for_session("skill-session-2")

    invoke_entry =
      find_entry!(session_entries, fn entry ->
        entry["event"] == "skill_invoke" and entry["task_summary"] == "Fix failing test"
      end)

    journal_entry =
      find_entry!(session_entries, fn entry ->
        entry["event"] == "skill_journal_write" and entry["path"] == "/tmp/fake-journal.md"
      end)

    assert_entries_in_order(session_entries, [invoke_entry, journal_entry])

    assert Enum.map(session_entries, & &1["event"]) == [
             "skill_invoke",
             "skill_journal_write"
           ]

    assert invoke_entry["event"] == "skill_invoke"
    assert invoke_entry["agent"] == "coding-skill"
    assert invoke_entry["skill"] == "coding-skill"
    assert invoke_entry["session_id"] == "skill-session-2"
    assert invoke_entry["task_summary"] == "Fix failing test"
    assert invoke_entry["success"] == true
    assert invoke_entry["duration_ms"] == 41
    assert invoke_entry["parent"] == "main"
    assert invoke_entry["parent_session"] == "main-session-2"

    assert journal_entry["event"] == "skill_journal_write"
    assert journal_entry["agent"] == "coding-skill"
    assert journal_entry["skill"] == "coding-skill"
    assert journal_entry["session_id"] == "skill-session-2"
    assert journal_entry["path"] == "/tmp/fake-journal.md"
    assert journal_entry["bytes"] == 512
  end
end
