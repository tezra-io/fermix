defmodule FermixOpik.LiveExportTest do
  @moduledoc """
  End-to-end through the live processes: Reporter → Aggregator → Sender → (stub
  client). Proves a real telemetry sequence reaches Opik as one assembled trace.
  """
  use ExUnit.Case, async: false

  alias FermixOpik.Aggregator
  alias FermixOpik.Reporter
  alias FermixOpik.Sender

  defmodule CaptureClient do
    @moduledoc false
    def send_trace(_config, closed, _opts \\ []) do
      send(:live_export_test, {:exported, closed})
      :ok
    end
  end

  setup do
    Process.register(self(), :live_export_test)
    config = %{base_url: "http://localhost:5173/api", api_key: nil, workspace: nil}

    sender =
      start_supervised!({Sender, config: config, client: CaptureClient, name: :live_sender})

    aggregator =
      start_supervised!(
        {Aggregator, project: "fermix", sender: sender, name: :live_aggregator, max_queue: 500}
      )

    :ok = Reporter.attach(aggregator: aggregator, handler_id: "live-export-test")

    on_exit(fn -> Reporter.detach("live-export-test") end)

    %{aggregator: aggregator}
  end

  test "a real provider+tool+message sequence exports one trace with three spans" do
    :telemetry.execute(
      [:fermix, :provider, :call],
      %{duration_ms: 1_000},
      %{
        provider: :openai,
        model: "gpt-5",
        status: :ok,
        session_id: "main-77",
        tokens: %{prompt: 12, completion: 3}
      }
    )

    :telemetry.execute(
      [:fermix, :tool, :exec],
      %{duration_ms: 20},
      %{tool: "shell", success: true, session_id: "main-77"}
    )

    :telemetry.execute(
      [:fermix, :agent, :message],
      %{iterations: 1, total_tokens: 15},
      %{channel: :telegram, chat_id: "c", sender: "u", session_id: "main-77", agent: "main"}
    )

    assert_receive {:exported, %{trace: trace, spans: spans}}, 2_000
    assert trace.name == "agent:main"
    assert length(spans) == 3
    assert Enum.any?(spans, &(&1[:type] == "llm"))
    assert Enum.any?(spans, &(&1[:type] == "tool"))
  end
end
