defmodule FermixCore.AgentLoopTest do
  use ExUnit.Case, async: true

  alias FermixCore.AgentLoop
  alias FermixCore.Capabilities.Builtin, as: BuiltinCapability
  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry

  # -- Mock adapter --

  defmodule MockAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(messages, capabilities, opts) do
      record_call(messages, capabilities, opts, :chat)
      next_response()
    end

    @impl true
    def continue(provider_state, tool_results, opts) do
      record_continue(provider_state, tool_results, opts)
      next_response()
    end

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false

    defp record_call(messages, capabilities, opts, _kind) do
      calls = Process.get(:mock_calls, [])
      Process.put(:mock_calls, calls ++ [{messages, capabilities, opts}])
    end

    defp record_continue(state, tool_results, opts) do
      cont = Process.get(:mock_continues, [])
      Process.put(:mock_continues, cont ++ [{state, tool_results, opts}])
    end

    defp next_response do
      case Process.get(:mock_responses, []) do
        [next | rest] ->
          Process.put(:mock_responses, rest)
          next

        [] ->
          {:error, "No mock responses left"}
      end
    end
  end

  # -- Mock tools wrapped as capabilities --

  defmodule EchoTool do
    @behaviour Tool

    @impl true
    def name, do: "echo"
    @impl true
    def description, do: "Echoes input"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}
    @impl true
    def execute(%{"text" => text}, _ctx), do: {:ok, Tool.success("Echo: #{text}")}
    def execute(_args, _ctx), do: {:ok, Tool.success("Echo: ")}
  end

  defmodule FailTool do
    @behaviour Tool

    @impl true
    def name, do: "fail_tool"
    @impl true
    def description, do: "Always fails"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}
    @impl true
    def execute(_args, _ctx), do: {:error, "tool exploded"}
  end

  defmodule SpyTool do
    @behaviour Tool

    @impl true
    def name, do: "spy_tool"
    @impl true
    def description, do: "Reports if it ran"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(_args, _ctx) do
      send(self(), :spy_tool_executed)
      {:ok, Tool.success("spy ran")}
    end
  end

  # -- Helpers --

  defp turn(content, opts \\ []) do
    tool_calls = Keyword.get(opts, :tool_calls, [])
    tokens = Keyword.get(opts, :total_tokens, 10)

    {:ok,
     %{
       content: content,
       tool_calls: tool_calls,
       provider_state: %{turn: System.unique_integer()},
       usage: %{prompt_tokens: tokens, completion_tokens: 0, total_tokens: tokens},
       model: "mock"
     }}
  end

  defp tool_call(call_id, name, arguments) do
    %{
      id: "fc_#{call_id}",
      call_id: call_id,
      name: name,
      arguments: Jason.encode!(arguments)
    }
  end

  defp set_mock_responses(responses) do
    Process.put(:mock_responses, responses)
    Process.put(:mock_calls, [])
    Process.put(:mock_continues, [])
  end

  defp mock_calls, do: Process.get(:mock_calls, [])
  defp mock_continues, do: Process.get(:mock_continues, [])

  defp register_caps(registry, modules) do
    Enum.each(modules, fn mod ->
      cap = BuiltinCapability.from_tool_module(mod)
      :ok = CapabilityRegistry.register(registry, cap)
    end)
  end

  defp run_loop(opts) do
    defaults = [
      messages: [%{role: "user", content: "hello"}],
      adapter: MockAdapter,
      adapter_opts: [model: "mock"],
      context: %{agent_name: "test", conversation_key: :test}
    ]

    AgentLoop.run(Keyword.merge(defaults, opts))
  end

  setup do
    name = :"capreg_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: name})
    %{registry: name}
  end

  # -- Simple response (no tool calls) --

  describe "run/1 with no tool calls" do
    test "returns final response from adapter", %{registry: registry} do
      set_mock_responses([turn("Hello there!")])

      assert {:ok, result} = run_loop(capability_registry: registry)
      assert result.response == "Hello there!"
      assert result.iterations == 1
      assert result.total_tokens == 10
    end

    test "returns response with correct token count", %{registry: registry} do
      set_mock_responses([turn("Hi", total_tokens: 42)])

      assert {:ok, result} = run_loop(capability_registry: registry)
      assert result.total_tokens == 42
    end
  end

  # -- Single tool call --

  describe "run/1 with single tool call" do
    test "executes capability and continues to terminal turn", %{registry: registry} do
      register_caps(registry, [EchoTool])

      set_mock_responses([
        turn("", tool_calls: [tool_call("call_1", "echo", %{"text" => "hi"})]),
        turn("Done!")
      ])

      assert {:ok, result} = run_loop(capability_registry: registry)
      assert result.response == "Done!"
      assert result.iterations == 2
      assert result.total_tokens == 20
    end

    test "passes capabilities + allowlist filter to adapter", %{registry: registry} do
      register_caps(registry, [EchoTool, FailTool])

      set_mock_responses([
        turn("", tool_calls: [tool_call("call_1", "echo", %{"text" => "hi"})]),
        turn("Done!")
      ])

      assert {:ok, _} = run_loop(capability_registry: registry, allowed_tools: ["echo"])

      [{_messages, capabilities, _opts}] = mock_calls()
      assert Enum.map(capabilities, & &1.name) == ["echo"]

      [{_state, [tool_result], _opts}] = mock_continues()
      assert tool_result.call_id == "call_1"
      assert tool_result.output == "Echo: hi"
    end
  end

  # -- Multiple tool calls in one turn --

  describe "run/1 with multiple tool calls" do
    test "executes every tool call and continues with all results", %{registry: registry} do
      register_caps(registry, [EchoTool])

      set_mock_responses([
        turn("",
          tool_calls: [
            tool_call("call_1", "echo", %{"text" => "a"}),
            tool_call("call_2", "echo", %{"text" => "b"})
          ]
        ),
        turn("All done")
      ])

      assert {:ok, result} = run_loop(capability_registry: registry)
      assert result.response == "All done"
      assert result.iterations == 2

      [{_state, results, _opts}] = mock_continues()
      assert Enum.map(results, & &1.call_id) == ["call_1", "call_2"]
      assert Enum.map(results, & &1.output) == ["Echo: a", "Echo: b"]
    end
  end

  # -- Iteration cap --

  describe "run/1 iteration cap" do
    test "returns error when max_iterations reached", %{registry: registry} do
      register_caps(registry, [EchoTool])

      endless =
        List.duplicate(
          turn("", tool_calls: [tool_call("call_n", "echo", %{"text" => "loop"})]),
          5
        )

      set_mock_responses(endless)

      assert {:error, msg} =
               run_loop(capability_registry: registry, max_iterations: 3)

      assert msg =~ "Maximum iterations"
      assert msg =~ "3"
    end
  end

  describe "run/1 loop detection" do
    test "injects a warning when identical tool calls hit the warn threshold", %{
      registry: registry
    } do
      register_caps(registry, [EchoTool])

      repeated = tool_call("call_same", "echo", %{"text" => "loop"})

      set_mock_responses([
        turn("", tool_calls: [repeated]),
        turn("", tool_calls: [repeated]),
        turn("", tool_calls: [repeated]),
        turn("Recovered")
      ])

      assert {:ok, result} =
               run_loop(
                 capability_registry: registry,
                 loop_detection_warn_threshold: 3,
                 loop_detection_kill_threshold: 5
               )

      assert result.response == "Recovered"
    end

    test "terminates when identical tool calls hit the kill threshold", %{registry: registry} do
      register_caps(registry, [EchoTool])

      repeated = tool_call("call_same", "echo", %{"text" => "loop"})
      set_mock_responses(List.duplicate(turn("", tool_calls: [repeated]), 5))

      assert {:error, reason} =
               run_loop(
                 capability_registry: registry,
                 max_iterations: 10,
                 loop_detection_warn_threshold: 3,
                 loop_detection_kill_threshold: 5
               )

      assert reason =~ "Repeated tool call loop detected"
    end
  end

  # -- Adapter error --

  describe "run/1 adapter error" do
    test "returns error when adapter fails", %{registry: registry} do
      set_mock_responses([{:error, "connection refused"}])

      assert {:error, "connection refused"} = run_loop(capability_registry: registry)
    end
  end

  # -- Capability not found --

  describe "run/1 capability not found" do
    test "returns error string in tool result for unknown capability", %{registry: registry} do
      set_mock_responses([
        turn("", tool_calls: [tool_call("call_1", "nonexistent", %{})]),
        turn("Handled missing tool")
      ])

      assert {:ok, result} = run_loop(capability_registry: registry)
      assert result.response == "Handled missing tool"

      [{_state, [tool_result], _opts}] = mock_continues()
      assert tool_result.output =~ "not found"
    end

    test "blocks disallowed tool calls without executing them", %{registry: registry} do
      register_caps(registry, [EchoTool, SpyTool])

      set_mock_responses([
        turn("", tool_calls: [tool_call("call_1", "spy_tool", %{})]),
        turn("Handled blocked tool")
      ])

      assert {:ok, result} =
               run_loop(capability_registry: registry, allowed_tools: ["echo"])

      assert result.response == "Handled blocked tool"
      refute_received :spy_tool_executed

      [{_state, [tool_result], _opts}] = mock_continues()
      assert tool_result.output =~ "not available"
    end

    test "policy-filtered capability cannot be dispatched even if registered", %{
      registry: registry
    } do
      # SpyTool is :read_only by default. Promote it to :exec so a third-party
      # trust default filters it out, but it stays in the registry.
      :ok = CapabilityRegistry.register(registry, BuiltinCapability.from_tool_module(EchoTool))

      :ok =
        CapabilityRegistry.register(registry, %{
          BuiltinCapability.from_tool_module(SpyTool)
          | policy_class: :exec
        })

      set_mock_responses([
        turn("", tool_calls: [tool_call("call_1", "spy_tool", %{})]),
        turn("Handled policy block")
      ])

      assert {:ok, result} = run_loop(capability_registry: registry, trust: :third_party)
      assert result.response == "Handled policy block"
      refute_received :spy_tool_executed

      [{_state, [tool_result], _opts}] = mock_continues()
      assert tool_result.output =~ "not found"
    end
  end

  # -- Capability execution error --

  describe "run/1 capability execution error" do
    test "returns error message in tool result", %{registry: registry} do
      register_caps(registry, [FailTool])

      set_mock_responses([
        turn("", tool_calls: [tool_call("call_1", "fail_tool", %{})]),
        turn("Handled error")
      ])

      assert {:ok, result} = run_loop(capability_registry: registry)
      assert result.response == "Handled error"
    end
  end

  # -- JSON argument parsing --

  describe "run/1 argument parsing" do
    test "handles already-decoded map arguments", %{registry: registry} do
      register_caps(registry, [EchoTool])

      call = %{
        id: "fc_call_1",
        call_id: "call_1",
        name: "echo",
        arguments: %{"text" => "direct"}
      }

      set_mock_responses([
        turn("", tool_calls: [call]),
        turn("OK")
      ])

      assert {:ok, result} = run_loop(capability_registry: registry)
      assert result.response == "OK"
    end

    test "handles malformed JSON gracefully", %{registry: registry} do
      register_caps(registry, [EchoTool])

      call = %{
        id: "fc_call_1",
        call_id: "call_1",
        name: "echo",
        arguments: "{bad json"
      }

      set_mock_responses([
        turn("", tool_calls: [call]),
        turn("Recovered")
      ])

      assert {:ok, result} = run_loop(capability_registry: registry)
      assert result.response == "Recovered"
    end
  end

  # -- Telemetry --

  describe "run/1 telemetry" do
    test "emits [:fermix, :agent, :iteration] for each iteration", %{registry: registry} do
      register_caps(registry, [EchoTool])
      test_pid = self()
      handler_id = "test-agent-iteration-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:fermix, :agent, :iteration],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      set_mock_responses([
        turn("", tool_calls: [tool_call("call_1", "echo", %{"text" => "hi"})], total_tokens: 15),
        turn("Done", total_tokens: 5)
      ])

      {:ok, _} = run_loop(capability_registry: registry)

      assert_received {:telemetry, [:fermix, :agent, :iteration], m1, meta1}
      assert is_integer(m1.duration_ms)
      assert meta1.iteration == 1
      assert meta1.has_tool_calls == true

      assert_received {:telemetry, [:fermix, :agent, :iteration], m2, meta2}
      assert is_integer(m2.duration_ms)
      assert meta2.iteration == 2
      assert meta2.has_tool_calls == false

      :telemetry.detach(handler_id)
    end
  end

  # -- Required options --

  describe "run/1 validation" do
    test "raises when messages not provided" do
      assert_raise KeyError, fn ->
        AgentLoop.run(adapter: MockAdapter, adapter_opts: [model: "mock"])
      end
    end
  end
end
