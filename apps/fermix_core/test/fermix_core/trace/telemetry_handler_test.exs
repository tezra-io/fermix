defmodule FermixCore.Trace.TelemetryHandlerTest do
  use ExUnit.Case, async: true

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

    [entry] = read_entries(dir, :tool_exec)
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

    [entry] = read_entries(dir, :tool_exec)
    assert entry["agent"] == "unknown"
  end
end
