defmodule FermixCore.Providers.TelemetryTest do
  use ExUnit.Case, async: false

  alias FermixCore.Providers.Telemetry, as: ProviderTelemetry

  setup do
    handler = "provider-tel-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:fermix, :provider, :call],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:provider_call, measurements, metadata})
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

  test "folds correlation ids into provider metadata" do
    metadata = %{
      provider: :openai,
      model: "gpt-5",
      status: :ok,
      tokens: %{prompt: 10, completion: 4}
    }

    ProviderTelemetry.emit_call(metadata, 1234,
      session_id: "cron_job-9_3",
      parent_session: "main-2"
    )

    assert_receive {:provider_call, %{duration_ms: 1234}, meta}
    assert meta.provider == :openai
    assert meta.model == "gpt-5"
    assert meta.session_id == "cron_job-9_3"
    assert meta.parent_session == "main-2"
  end

  test "omits absent correlation ids" do
    ProviderTelemetry.emit_call(%{provider: :openai, model: "gpt-5"}, 10, session_id: "main-1")

    assert_receive {:provider_call, _measurements, meta}
    assert meta.session_id == "main-1"
    refute Map.has_key?(meta, :parent_session)
  end

  test "omits output/tool_calls when content capture is disabled" do
    set_capture_content(false)

    ProviderTelemetry.emit_call(%{provider: :openai, model: "gpt-5"}, 10,
      output: "the answer is 42",
      tool_calls: [%{"function" => %{"name" => "shell"}}]
    )

    assert_receive {:provider_call, _measurements, meta}
    refute Map.has_key?(meta, :output)
    refute Map.has_key?(meta, :tool_calls)
  end

  test "attaches output preview and tool-call names when content capture is enabled" do
    set_capture_content(true)

    ProviderTelemetry.emit_call(%{provider: :openai, model: "gpt-5"}, 10,
      output: "the answer is 42",
      tool_calls: [%{"function" => %{"name" => "shell"}}, %{name: "file_read"}]
    )

    assert_receive {:provider_call, _measurements, meta}
    assert meta.output == "the answer is 42"
    assert meta.tool_calls == ["shell", "file_read"]
  end
end
