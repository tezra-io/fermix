defmodule FermixCore.Capabilities.MCP.CapabilityTest do
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.MCP.Capability, as: McpCapability
  alias FermixCore.Capabilities.MCP.Naming

  defmodule StubCaller do
    @behaviour FermixCore.Capabilities.MCP.Caller

    @table :mcp_capability_stub_caller

    def init do
      cleanup()
      :ets.new(@table, [:named_table, :public, :set])
      :ok
    end

    def cleanup do
      case :ets.whereis(@table) do
        :undefined -> :ok
        tid -> :ets.delete(tid)
      end
    end

    def set_response(server, tool, response) do
      :ets.insert(@table, {{server, tool}, response})
      :ok
    end

    @impl true
    def call_tool(server, tool, _args) do
      case :ets.lookup(@table, {server, tool}) do
        [{_, response}] -> response
        [] -> {:error, :no_stub_response}
      end
    end
  end

  setup do
    Naming.init()
    :ok = StubCaller.init()

    on_exit(fn ->
      StubCaller.cleanup()

      case :ets.whereis(Naming) do
        :undefined -> :ok
        tid -> :ets.delete_all_objects(tid)
      end
    end)

    :ok
  end

  describe "from_tool_descriptor/3" do
    test "produces a :mcp capability with sanitized name and metadata" do
      descriptor = %{
        name: "create_issue",
        description: "Create a GitHub issue.",
        input_schema: %{type: "object", properties: %{title: %{type: "string"}}}
      }

      cap = McpCapability.from_tool_descriptor("github", descriptor, caller: StubCaller)

      assert %Capability{kind: :mcp, name: "mcp_github_create_issue"} = cap
      assert cap.policy_class == :external_api
      assert cap.hidden_from_agent? == false
      assert cap.metadata.mcp_server == "github"
      assert cap.metadata.original_name == "create_issue"
      assert cap.metadata.sanitized_name == "mcp_github_create_issue"
      assert cap.parameters == descriptor.input_schema

      assert {McpCapability, :invoke,
              ["github", "create_issue", "mcp_github_create_issue", StubCaller]} = cap.executor
    end

    test "tool_overrides flip hidden_from_agent? to true" do
      descriptor = %{name: "read_file", description: "Read a file.", input_schema: %{}}

      cap =
        McpCapability.from_tool_descriptor("filesystem", descriptor,
          caller: StubCaller,
          tool_overrides: %{policy_class: :read_only, hidden_from_agent?: true}
        )

      assert cap.policy_class == :read_only
      assert cap.hidden_from_agent? == true
    end

    test "raises when descriptor has no :name" do
      assert_raise ArgumentError, fn ->
        McpCapability.from_tool_descriptor("github", %{description: "no name"})
      end
    end
  end

  describe "invoke/5" do
    test "returns a tool success result on a successful MCP call" do
      descriptor = %{name: "create_issue", description: "x", input_schema: %{}}

      cap = McpCapability.from_tool_descriptor("github", descriptor, caller: StubCaller)
      :ok = StubCaller.set_response("github", "create_issue", {:ok, "issue #42 created"})

      assert {:ok, result} = Capability.execute(cap, %{"title" => "Test"}, %{})
      assert result.success
      assert result.output =~ "issue #42 created"
    end

    test "returns a tool error when the caller returns {:error, reason}" do
      descriptor = %{name: "create_issue", description: "x", input_schema: %{}}

      cap = McpCapability.from_tool_descriptor("github", descriptor, caller: StubCaller)
      :ok = StubCaller.set_response("github", "create_issue", {:error, :unauthorized})

      assert {:ok, result} = Capability.execute(cap, %{"title" => "Test"}, %{})
      refute result.success
      assert result.error =~ "MCP tool 'github/create_issue' failed"
      assert result.error =~ "unauthorized"
    end
  end

  describe "invoke/6 telemetry" do
    setup do
      handler = "mcp-capability-telemetry-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:fermix, :tool, :exec],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:tool_exec, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "emits [:fermix, :tool, :exec] with the sanitized name, server, and correlation on success" do
      descriptor = %{name: "create_issue", description: "x", input_schema: %{}}
      cap = McpCapability.from_tool_descriptor("github", descriptor, caller: StubCaller)
      :ok = StubCaller.set_response("github", "create_issue", {:ok, "issue #42 created"})

      context = %{agent_name: "main", session_id: "main-7", parent_session: "cron-1"}
      assert {:ok, result} = Capability.execute(cap, %{"title" => "T"}, context)
      assert result.success

      assert_receive {:tool_exec, %{duration_ms: duration}, metadata}
      assert is_integer(duration) and duration >= 0
      assert metadata.tool == "mcp_github_create_issue"
      assert metadata.agent == "main"
      assert metadata.success == true
      assert metadata.mcp_server == "github"
      assert metadata.session_id == "main-7"
      assert metadata.parent_session == "cron-1"
    end

    test "emits success: false with the error reason on a failed MCP call" do
      descriptor = %{name: "create_issue", description: "x", input_schema: %{}}
      cap = McpCapability.from_tool_descriptor("github", descriptor, caller: StubCaller)
      :ok = StubCaller.set_response("github", "create_issue", {:error, :unauthorized})

      assert {:ok, result} = Capability.execute(cap, %{}, %{agent_name: "main"})
      refute result.success

      assert_receive {:tool_exec, _measurements, metadata}
      assert metadata.tool == "mcp_github_create_issue"
      assert metadata.success == false
      assert metadata.mcp_server == "github"
      assert metadata.error =~ "unauthorized"
    end
  end
end
