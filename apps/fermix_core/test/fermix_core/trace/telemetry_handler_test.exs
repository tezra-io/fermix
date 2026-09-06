defmodule FermixCore.Trace.TelemetryHandlerTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.LifecycleTelemetry
  alias FermixCore.Capabilities.MCP.Telemetry, as: MCPClientTelemetry
  alias FermixCore.Trace
  alias FermixCore.Trace.TelemetryHandler

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "fermix_tel_#{System.unique_integer([:positive])}")
    name = :"tel_trace_#{System.unique_integer([:positive])}"
    start_supervised!({Trace, base_dir: tmp_dir, name: name})

    prefix = "test-#{System.unique_integer([:positive])}"
    TelemetryHandler.attach(trace_server: name, handler_prefix: prefix)

    # `task_summary` is prompt content and obeys `capture_content`, so every
    # test here establishes the switch it needs rather than reading whatever an
    # earlier module left in the global app env.
    prior_telemetry = Application.get_env(:fermix_core, :telemetry, [])
    capture_content(true)

    on_exit(fn ->
      TelemetryHandler.detach(prefix)
      Application.put_env(:fermix_core, :telemetry, prior_telemetry)
      FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
    end)

    %{dir: tmp_dir, server: name}
  end

  defp capture_content(enabled?) do
    prior = Application.get_env(:fermix_core, :telemetry, [])
    Application.put_env(:fermix_core, :telemetry, Keyword.put(prior, :capture_content, enabled?))
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

  test "handle_event routes via the BAKED definition, not by re-looking up the event", %{
    dir: dir,
    server: server
  } do
    # Discriminating test: feed an event that the pre-change code would have
    # looked up to :llm_call ([:fermix, :provider, :call]) but bake the *tool*
    # definition (:tool_exec) into the config. The new handler routes by the
    # baked definition, so this MUST land as tool_exec with NO llm_call row.
    # Against the old event-lookup code it would land as llm_call and this
    # assertion fails — that is the regression guard.
    tool_def = %{event: [:fermix, :tool, :exec], trace_type: :tool_exec, agent_field: :agent}

    TelemetryHandler.handle_event(
      [:fermix, :provider, :call],
      %{duration_ms: 12},
      %{agent: "main", tool: "shell"},
      %{trace_server: server, definition: tool_def}
    )

    sync(server)

    llm_call_path = Path.join([dir, Date.utc_today() |> Date.to_iso8601(), "llm_call.jsonl"])
    refute File.exists?(llm_call_path)

    tool = find_entry!(read_entries(dir, :tool_exec), &(&1["tool"] == "shell"))
    assert tool["type"] == "tool_exec"
    assert tool["agent"] == "main"

    # And a custom trace_event in the baked definition is honored verbatim.
    failover_def = %{
      event: [:fermix, :provider, :failover],
      trace_type: :agent_event,
      agent_field: :agent,
      trace_event: "provider_failover"
    }

    TelemetryHandler.handle_event(
      failover_def.event,
      %{},
      %{agent: "main", from: "openai", to: "anthropic"},
      %{trace_server: server, definition: failover_def}
    )

    sync(server)

    failover = find_entry!(read_entries(dir, :agent_event), &(&1["event"] == "provider_failover"))
    assert failover["type"] == "agent_event"
    assert failover["to"] == "anthropic"
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

  test "mcp inbound call event creates tool_exec trace", %{dir: dir, server: server} do
    :telemetry.execute(
      [:fermix, :mcp, :inbound, :call],
      %{duration_ms: 42},
      %{
        client_name: "Claude Desktop",
        client_version: "0.7.4",
        session_id: "mcp-session",
        tool_name: "memory_recall",
        tool_kind: :builtin,
        tool_policy_class: :read_only,
        result: {:error, :invalid_params}
      }
    )

    sync(server)

    entries = read_entries(dir, :tool_exec)
    entry = Enum.find(entries, &(&1["tool_name"] == "memory_recall"))
    assert entry["agent"] == "Claude Desktop"
    assert entry["duration_ms"] == 42
    assert entry["session_id"] == "mcp-session"
    assert entry["result"] == "{:error, :invalid_params}"
  end

  test "mcp inbound tools_listed event creates agent_event trace", %{dir: dir, server: server} do
    :telemetry.execute(
      [:fermix, :mcp, :inbound, :tools_listed],
      %{count: 3},
      %{client_name: "Cursor", client_version: "1.2.3", session_id: "mcp-session"}
    )

    sync(server)

    entries = read_entries(dir, :agent_event)
    entry = Enum.find(entries, &(&1["event"] == "mcp_inbound_tools_listed"))
    assert entry["agent"] == "Cursor"
    assert entry["count"] == 3
    assert entry["session_id"] == "mcp-session"
  end

  # Registry-completeness invariant (CLAUDE.md "gate on the whole feature
  # surface"): the assertion is "NO phase this emitter can emit is missing from
  # the JSONL stream", written as a loop over `phases/0` so a phase added later
  # either joins the invariant or fails here.
  test "every outbound-MCP lifecycle phase reaches the JSONL trace stream", %{
    dir: dir,
    server: server
  } do
    phases = MCPClientTelemetry.phases()
    assert :telemetry.list_handlers(MCPClientTelemetry.lifecycle_event()) != []

    for phase <- phases do
      MCPClientTelemetry.emit_lifecycle(
        phase,
        %{source_id: {:plugin, "eden"}, plugin: "eden"},
        :ok,
        7
      )
    end

    sync(server)

    entries = read_entries(dir, :agent_event)
    lifecycle = Enum.filter(entries, &(&1["event"] == "mcp_client_lifecycle"))

    assert Enum.map(lifecycle, & &1["phase"]) == Enum.map(phases, &to_string/1)
    assert Enum.all?(lifecycle, &(&1["agent"] == "plugin:eden"))
    assert Enum.all?(lifecycle, &(&1["source_id"] == "plugin:eden"))
    assert Enum.all?(lifecycle, &(&1["duration_ms"] == 7))
  end

  test "mcp_client lifecycle rows carry the redacted error class", %{dir: dir, server: server} do
    MCPClientTelemetry.emit_lifecycle(
      :security_block,
      %{source_id: {:operator, "fs"}},
      {:error, {:tool_not_allowed, "eden_delete_note"}},
      3,
      session_id: "main-9",
      attempt: 2
    )

    sync(server)

    entry = find_entry!(read_entries(dir, :agent_event), &(&1["event"] == "mcp_client_lifecycle"))
    assert entry["agent"] == "operator:fs"
    assert entry["result"] == "error"
    assert entry["error_class"] == "tool_not_allowed"
    assert entry["session_id"] == "main-9"
    assert entry["attempt"] == 2
  end

  test "capability:mcp_name_collision event creates an agent_event trace", %{
    dir: dir,
    server: server
  } do
    MCPClientTelemetry.emit_collision(
      "fs-local",
      "read_file",
      "mcp_fs_local_read_file",
      {"fs.local", "read_file"}
    )

    sync(server)

    entry = find_entry!(read_entries(dir, :agent_event), &(&1["event"] == "mcp_name_collision"))
    assert entry["agent"] == "fs-local"
    assert entry["original"] == "read_file"
    assert entry["sanitized"] == "mcp_fs_local_read_file"
    assert entry["collided_with"] == %{"server" => "fs.local", "original" => "read_file"}
    assert entry["count"] == 1
  end

  test "plugin:dist event creates a plugin_dist agent_event trace", %{dir: dir, server: server} do
    :telemetry.execute(
      [:fermix, :plugin, :dist],
      %{duration_ms: 87},
      %{op: :install, plugin: "github", version: "1.2.0", result: :installed, reason: nil}
    )

    sync(server)

    entries = read_entries(dir, :agent_event)
    entry = find_entry!(entries, &(&1["event"] == "plugin_dist"))
    assert entry["agent"] == "install"
    assert entry["plugin"] == "github"
    assert entry["version"] == "1.2.0"
    assert entry["result"] == "installed"
    assert entry["duration_ms"] == 87
  end

  test "timeout:expired event creates a timeout agent_event trace", %{dir: dir, server: server} do
    :telemetry.execute(
      [:fermix, :timeout, :expired],
      %{ms: 30_000},
      %{name: :cu_sidecar_action, session_id: "cua_1"}
    )

    sync(server)

    entries = read_entries(dir, :agent_event)
    entry = find_entry!(entries, &(&1["event"] == "timeout"))
    assert entry["agent"] == "cu_sidecar_action"
    assert entry["session_id"] == "cua_1"
    assert entry["ms"] == 30_000
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

  test "channel:reply event creates a reply_delivery agent_event trace", %{
    dir: dir,
    server: server
  } do
    :telemetry.execute(
      [:fermix, :channel, :reply],
      %{duration_us: 1200},
      %{channel: "telegram", reply_type: :text, status: :ok}
    )

    sync(server)

    entries = read_entries(dir, :agent_event)
    entry = find_entry!(entries, &(&1["event"] == "reply_delivery"))
    assert entry["agent"] == "telegram"
    assert entry["reply_type"] == "text"
    assert entry["status"] == "ok"
    assert entry["duration_us"] == 1200
  end

  test "channel:pair event creates a bounded channel_pair agent_event trace", %{
    dir: dir,
    server: server
  } do
    :telemetry.execute(
      [:fermix, :channel, :pair],
      %{count: 1, duration_us: 42},
      %{channel: :mobile, status: :approved}
    )

    sync(server)

    entries = read_entries(dir, :agent_event)
    entry = find_entry!(entries, &(&1["event"] == "channel_pair"))
    assert entry["agent"] == "mobile"
    assert entry["channel"] == "mobile"
    assert entry["status"] == "approved"
    assert entry["count"] == 1
    assert entry["duration_us"] == 42
    refute Map.has_key?(entry, "content")
  end

  test "channel:push event creates a bounded channel_push agent_event trace", %{
    dir: dir,
    server: server
  } do
    :telemetry.execute(
      [:fermix, :channel, :push],
      %{count: 1, duration_us: 73},
      %{channel: :mobile, status: :failed}
    )

    sync(server)

    entries = read_entries(dir, :agent_event)
    entry = find_entry!(entries, &(&1["event"] == "channel_push"))
    assert entry["agent"] == "mobile"
    assert entry["channel"] == "mobile"
    assert entry["status"] == "failed"
    assert entry["count"] == 1
    assert entry["duration_us"] == 73
    refute Map.has_key?(entry, "content")
  end

  test "channel:transport event creates a bounded channel_transport agent_event trace", %{
    dir: dir,
    server: server
  } do
    :telemetry.execute(
      [:fermix, :channel, :transport],
      %{count: 1, consecutive_failures: 312},
      %{channel: :telegram, status: :degraded, error_class: :timeout}
    )

    sync(server)

    entries = read_entries(dir, :agent_event)
    entry = find_entry!(entries, &(&1["event"] == "channel_transport"))
    assert entry["agent"] == "telegram"
    assert entry["channel"] == "telegram"
    assert entry["status"] == "degraded"
    assert entry["error_class"] == "timeout"
    assert entry["consecutive_failures"] == 312
    refute Map.has_key?(entry, "content")
  end

  test "memory:review event creates a memory_review agent_event trace", %{
    dir: dir,
    server: server
  } do
    :telemetry.execute(
      [:fermix, :memory, :review],
      %{duration_us: 1_500_000, ops_added: 1, ops_replaced: 0, ops_archived: 0, ops_skipped: 0},
      %{
        agent: "main",
        session_id: "memory_review:main:telegram:c1:root:42",
        conversation_key: "telegram:c1:root",
        channel: "telegram",
        chat_id: "c1",
        status: :ok,
        fired: true
      }
    )

    sync(server)

    entries = read_entries(dir, :agent_event)
    entry = find_entry!(entries, &(&1["event"] == "memory_review"))
    assert entry["agent"] == "main"
    assert entry["session_id"] == "memory_review:main:telegram:c1:root:42"
    assert entry["status"] == "ok"
    assert entry["ops_added"] == 1
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

  # A task summary is the leading text of the delegated prompt — the owner's own
  # words. `capture_content: false` means "no prompt or response bodies in
  # traces", so the summary must not ride the lifecycle event either. The
  # posture is ESTABLISHED here rather than assumed — content capture is on by
  # default now, and a test that reads a global default instead of setting one
  # is the order-dependent flake this file has had before. The Opik exporter
  # renders this field as the trace's `input`, so leaking it here leaks it off
  # the machine.
  test "task summaries stay out of traces when content capture is off", %{
    dir: dir,
    server: server
  } do
    capture_content(false)

    LifecycleTelemetry.agent_task_start(
      "coding-skill",
      :skill,
      "private-session-1",
      "Book the clinic appointment for Dr Vance"
    )

    LifecycleTelemetry.skill_invoke(
      "coding",
      "private-session-2",
      "Book the clinic appointment for Dr Vance",
      true,
      12,
      "main-session-1"
    )

    sync(server)
    entries = read_entries(dir, :agent_event)

    for session <- ~w(private-session-1 private-session-2) do
      entry = find_entry!(entries, &(&1["session_id"] == session))
      refute Map.has_key?(entry, "task_summary")
      assert entry["session_id"] == session
    end

    refute File.read!(Path.join([dir, Date.to_iso8601(Date.utc_today()), "agent_event.jsonl"])) =~
             "Dr Vance"
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
