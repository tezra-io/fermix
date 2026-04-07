defmodule FermixCore.AgentLoopTest do
  use ExUnit.Case, async: true

  alias FermixCore.AgentLoop
  alias FermixCore.Tools.Registry
  alias FermixCore.Tools.Tool

  # -- Mock provider --

  defmodule MockProvider do
    @behaviour FermixCore.Providers.Provider

    @impl true
    def chat(messages, opts) do
      calls = Process.get(:mock_calls, [])
      Process.put(:mock_calls, calls ++ [{messages, opts}])

      responses = Process.get(:mock_responses, [])

      case responses do
        [next | rest] ->
          Process.put(:mock_responses, rest)
          next

        [] ->
          {:error, "No mock responses left"}
      end
    end

    @impl true
    def models, do: {:ok, ["mock-model"]}
  end

  # -- Mock tools --

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

  defp mock_response(content, opts \\ []) do
    tool_calls = Keyword.get(opts, :tool_calls, [])
    tokens = Keyword.get(opts, :total_tokens, 10)

    {:ok,
     %{
       content: content,
       tool_calls: tool_calls,
       usage: %{prompt_tokens: tokens, completion_tokens: 0, total_tokens: tokens}
     }}
  end

  defp tool_call(id, name, arguments) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => Jason.encode!(arguments)}
    }
  end

  defp set_mock_responses(responses) do
    Process.put(:mock_responses, responses)
    Process.put(:mock_calls, [])
  end

  defp mock_calls do
    Process.get(:mock_calls, [])
  end

  defp run_loop(opts) do
    defaults = [
      messages: [%{role: "user", content: "hello"}],
      provider: MockProvider,
      model: "mock",
      temperature: 0.0,
      context: %{agent_name: "test", conversation_key: :test}
    ]

    AgentLoop.run(Keyword.merge(defaults, opts))
  end

  setup do
    registry = start_supervised!({Registry, name: :"registry_#{System.unique_integer()}"})
    %{registry: registry}
  end

  # -- Simple response (no tool calls) --

  describe "run/1 with no tool calls" do
    test "returns final response from provider" do
      set_mock_responses([mock_response("Hello there!")])

      assert {:ok, result} = run_loop([])
      assert result.response == "Hello there!"
      assert result.iterations == 1
      assert result.total_tokens == 10
    end

    test "returns response with correct token count" do
      set_mock_responses([mock_response("Hi", total_tokens: 42)])

      assert {:ok, result} = run_loop([])
      assert result.total_tokens == 42
    end
  end

  # -- Single tool call --

  describe "run/1 with single tool call" do
    test "executes tool and loops to get final response", %{registry: registry} do
      :ok = Registry.register(registry, EchoTool)

      set_mock_responses([
        mock_response("", tool_calls: [tool_call("call_1", "echo", %{"text" => "hi"})]),
        mock_response("Done!")
      ])

      assert {:ok, result} = run_loop(tools: [], registry: registry)
      assert result.response == "Done!"
      assert result.iterations == 2
      assert result.total_tokens == 20
    end

    test "executes allowed tools when allowlist permits them", %{registry: registry} do
      :ok = Registry.register(registry, EchoTool)

      set_mock_responses([
        mock_response("", tool_calls: [tool_call("call_1", "echo", %{"text" => "hi"})]),
        mock_response("Done!")
      ])

      assert {:ok, result} =
               run_loop(
                 tools: Registry.all_tools_for_llm(registry),
                 allowed_tools: ["echo"],
                 registry: registry
               )

      assert result.response == "Done!"

      [{_messages, first_opts}, {second_messages, _second_opts}] = mock_calls()
      assert Enum.map(first_opts[:tools], & &1.function.name) == ["echo"]
      assert Enum.any?(second_messages, &(&1.role == "tool" and &1.content == "Echo: hi"))
    end
  end

  # -- Multiple tool calls in one response --

  describe "run/1 with multiple tool calls" do
    test "executes all tools and includes all results", %{registry: registry} do
      :ok = Registry.register(registry, EchoTool)

      set_mock_responses([
        mock_response("",
          tool_calls: [
            tool_call("call_1", "echo", %{"text" => "a"}),
            tool_call("call_2", "echo", %{"text" => "b"})
          ]
        ),
        mock_response("All done")
      ])

      assert {:ok, result} = run_loop(tools: [], registry: registry)
      assert result.response == "All done"
      assert result.iterations == 2
    end
  end

  # -- Iteration cap --

  describe "run/1 iteration cap" do
    test "returns error when max_iterations reached", %{registry: registry} do
      :ok = Registry.register(registry, EchoTool)

      # Every response has tool calls — never terminates
      endless =
        List.duplicate(
          mock_response("", tool_calls: [tool_call("call_n", "echo", %{"text" => "loop"})]),
          3
        )

      set_mock_responses(endless)

      assert {:error, msg} = run_loop(max_iterations: 3, tools: [], registry: registry)
      assert msg =~ "Maximum iterations"
      assert msg =~ "3"
    end
  end

  # -- Provider error --

  describe "run/1 provider error" do
    test "returns error when provider fails" do
      set_mock_responses([{:error, "connection refused"}])

      assert {:error, "connection refused"} = run_loop([])
    end
  end

  # -- Tool not found --

  describe "run/1 tool not found" do
    test "returns error string in tool result for unknown tool", %{registry: registry} do
      # Registry has no tools registered
      set_mock_responses([
        mock_response("", tool_calls: [tool_call("call_1", "nonexistent", %{})]),
        mock_response("Handled missing tool")
      ])

      assert {:ok, result} = run_loop(tools: [], registry: registry)
      assert result.response == "Handled missing tool"
    end

    test "blocks disallowed tool calls without executing them", %{registry: registry} do
      :ok = Registry.register(registry, EchoTool)
      :ok = Registry.register(registry, SpyTool)

      set_mock_responses([
        mock_response("", tool_calls: [tool_call("call_1", "spy_tool", %{})]),
        mock_response("Handled blocked tool")
      ])

      assert {:ok, result} =
               run_loop(
                 tools: Registry.all_tools_for_llm(registry),
                 allowed_tools: ["echo"],
                 registry: registry
               )

      assert result.response == "Handled blocked tool"
      refute_received :spy_tool_executed

      [{_messages, first_opts}, {second_messages, _second_opts}] = mock_calls()
      assert Enum.map(first_opts[:tools], & &1.function.name) == ["echo"]

      assert Enum.any?(
               second_messages,
               &(&1.role == "tool" and &1.content == "Error: Tool 'spy_tool' not available")
             )
    end
  end

  # -- Tool execution error --

  describe "run/1 tool execution error" do
    test "returns error message in tool result", %{registry: registry} do
      :ok = Registry.register(registry, FailTool)

      set_mock_responses([
        mock_response("", tool_calls: [tool_call("call_1", "fail_tool", %{})]),
        mock_response("Handled error")
      ])

      assert {:ok, result} = run_loop(tools: [], registry: registry)
      assert result.response == "Handled error"
    end
  end

  # -- JSON argument parsing --

  describe "run/1 argument parsing" do
    test "handles already-decoded map arguments", %{registry: registry} do
      :ok = Registry.register(registry, EchoTool)

      # Simulate arguments as a map (not JSON string)
      call = %{
        "id" => "call_1",
        "type" => "function",
        "function" => %{"name" => "echo", "arguments" => %{"text" => "direct"}}
      }

      set_mock_responses([
        mock_response("", tool_calls: [call]),
        mock_response("OK")
      ])

      assert {:ok, result} = run_loop(tools: [], registry: registry)
      assert result.response == "OK"
    end

    test "handles malformed JSON gracefully", %{registry: registry} do
      :ok = Registry.register(registry, EchoTool)

      call = %{
        "id" => "call_1",
        "type" => "function",
        "function" => %{"name" => "echo", "arguments" => "{bad json"}
      }

      set_mock_responses([
        mock_response("", tool_calls: [call]),
        mock_response("Recovered")
      ])

      assert {:ok, result} = run_loop(tools: [], registry: registry)
      assert result.response == "Recovered"
    end
  end

  # -- Telemetry --

  describe "run/1 telemetry" do
    test "emits [:fermix, :agent, :iteration] for each iteration", %{registry: registry} do
      :ok = Registry.register(registry, EchoTool)
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
        mock_response("",
          tool_calls: [tool_call("call_1", "echo", %{"text" => "hi"})],
          total_tokens: 15
        ),
        mock_response("Done", total_tokens: 5)
      ])

      {:ok, _} = run_loop(tools: [], registry: registry)

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
        AgentLoop.run(provider: MockProvider)
      end
    end
  end
end
