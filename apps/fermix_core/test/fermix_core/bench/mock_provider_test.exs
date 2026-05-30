defmodule FermixCore.Bench.MockProviderTest do
  use ExUnit.Case, async: true

  alias FermixCore.Bench.MockProvider
  alias FermixCore.Capabilities.Capability

  test "returns one scripted tool call then a terminal response" do
    capability = capability("bench_echo")

    assert {:ok, first} =
             MockProvider.chat([%{role: "user", content: "hello"}], [capability],
               bench_script: :tool_once
             )

    assert [%{name: "bench_echo", call_id: "bench_call_1"}] = first.tool_calls

    assert {:ok, second} =
             MockProvider.continue(
               first.provider_state,
               [%{call_id: "bench_call_1", output: "ok"}],
               bench_script: :tool_once
             )

    assert second.content == "bench final"
    assert second.tool_calls == []
  end

  test "emits provider call and tool schema telemetry" do
    test_pid = self()
    handler_id = "bench-mock-provider-#{System.unique_integer()}"

    :telemetry.attach_many(
      handler_id,
      [[:fermix, :provider, :call], [:fermix, :provider, :tool_schema]],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _turn} =
             MockProvider.chat([%{role: "user", content: "hello"}], [capability("bench_1")],
               bench_script: :text
             )

    assert_receive {:telemetry, [:fermix, :provider, :tool_schema], tool_measurements,
                    %{adapter: :bench_mock}}

    assert tool_measurements.duration_us >= 0
    assert tool_measurements.tools_count == 1

    assert_receive {:telemetry, [:fermix, :provider, :call], call_measurements,
                    %{adapter: :bench_mock, status: :ok}}

    assert call_measurements.duration_ms >= 0
  end

  defp capability(name) do
    Capability.new(%{
      name: name,
      description: "Bench tool #{name}",
      parameters: %{type: "object", properties: %{}, additionalProperties: false},
      kind: :builtin,
      executor: {Kernel, :inspect, []}
    })
  end
end
