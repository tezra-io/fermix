defmodule FermixCore.Tools.TelemetryTest do
  use ExUnit.Case, async: false

  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  setup do
    handler = "tool-tel-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:fermix, :tool, :exec],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:tool_exec, measurements, metadata})
      end,
      nil
    )

    prior = Application.get_env(:fermix_core, :telemetry, [])

    on_exit(fn ->
      :telemetry.detach(handler)
      Application.put_env(:fermix_core, :telemetry, prior)
    end)

    :ok
  end

  defp set_capture_content(value) do
    Application.put_env(:fermix_core, :telemetry, capture_content: value)
  end

  test "emits agent and correlation ids from context" do
    context = %{
      agent_name: "scheduled:job-1",
      session_id: "cron_job-1_42",
      parent_session: "main-7"
    }

    ToolTelemetry.exec("shell", context, true, 12, metadata: %{plugin: "builtin"})

    assert_receive {:tool_exec, %{duration_ms: 12}, metadata}
    assert metadata.tool == "shell"
    assert metadata.agent == "scheduled:job-1"
    assert metadata.success == true
    assert metadata.session_id == "cron_job-1_42"
    assert metadata.parent_session == "main-7"
    assert metadata.plugin == "builtin"
  end

  test "defaults agent to unknown and omits absent correlation ids" do
    ToolTelemetry.exec("file_read", %{}, false, 3)

    assert_receive {:tool_exec, _measurements, metadata}
    assert metadata.agent == "unknown"
    refute Map.has_key?(metadata, :session_id)
    refute Map.has_key?(metadata, :parent_session)
  end

  test "a caller cannot override authoritative fields via metadata" do
    context = %{agent_name: "main", session_id: "main-1"}

    ToolTelemetry.exec("file_write", context, true, 5,
      metadata: %{tool: "spoofed", agent: "evil", success: false}
    )

    assert_receive {:tool_exec, _measurements, metadata}
    assert metadata.tool == "file_write"
    assert metadata.agent == "main"
    assert metadata.success == true
  end

  test "content is omitted when capture is disabled" do
    set_capture_content(false)
    context = %{agent_name: "main", session_id: "main-1"}

    ToolTelemetry.exec("shell", context, true, 5, input: "ls -la", output: "file listing")

    assert_receive {:tool_exec, _measurements, metadata}
    refute Map.has_key?(metadata, :input)
    refute Map.has_key?(metadata, :output)
  end

  test "content is attached whole when capture is enabled" do
    set_capture_content(true)
    context = %{agent_name: "main", session_id: "main-1"}
    big_output = String.duplicate("x", 5_000)

    ToolTelemetry.exec("shell", context, true, 5, input: "ls -la", output: big_output)

    assert_receive {:tool_exec, _measurements, metadata}
    assert metadata.input == "ls -la"
    # Capture on means full fidelity — no 2k truncation (that bound applies
    # only when capture is off; see FermixCore.TelemetryTest).
    assert metadata.output == big_output
  end

  test "a failed result's error text is previewed as output when capture is enabled" do
    set_capture_content(true)
    context = %{agent_name: "main", session_id: "main-1"}
    # Builtin failures (Tool.error/1) carry output: "" — the error text is the
    # body worth tracing, and an empty output must not shadow it.
    error_text = "boom (code): {\"console\":[]}"
    result = {:ok, %{success: false, output: "", error: error_text}}

    ToolTelemetry.exec("browser", context, false, 5, result: result)

    assert_receive {:tool_exec, _measurements, metadata}
    assert metadata.output == error_text
  end
end
