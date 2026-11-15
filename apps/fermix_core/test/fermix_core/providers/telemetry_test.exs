defmodule FermixCore.Providers.TelemetryTest do
  use ExUnit.Case, async: false

  alias FermixCore.ComputerHistory.Summarizer
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

  # M97 D10: a computer-history summary call carries the owner's raw activity;
  # a trace or an Opik export keeping it would be a second raw store.
  test "a computer-history summary call never carries its content, capture on or not" do
    set_capture_content(true)
    agent = Summarizer.summarizer_agent()
    assert agent in ProviderTelemetry.content_withheld()

    ProviderTelemetry.emit_call(%{provider: :ollama, model: "llama3", agent: agent}, 10,
      session_id: "computer_history_summarize:1",
      input: "text=\"the owner's draft\"",
      output: "Drafted a note.",
      tool_calls: [%{name: "x"}]
    )

    assert_receive {:provider_call, %{duration_ms: 10}, meta}
    assert meta.content_withheld == true
    assert meta.session_id == "computer_history_summarize:1"
    refute Map.has_key?(meta, :input)
    refute Map.has_key?(meta, :output)
    refute Map.has_key?(meta, :tool_calls)
  end

  test "the roll-up, which reads notes and never raw activity, keeps the capture setting" do
    set_capture_content(true)

    ProviderTelemetry.emit_call(
      %{provider: :ollama, model: "llama3", agent: "computer_history_rollup"},
      10,
      output: "Thread: the lease."
    )

    assert_receive {:provider_call, _measurements, meta}
    assert meta.output == "Thread: the lease."
    refute Map.has_key?(meta, :content_withheld)
  end
end
