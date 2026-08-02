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

    def set_response(source_id, tool, response) do
      :ets.insert(@table, {{source_id, tool}, response})
      :ok
    end

    def last_context, do: :persistent_term.get({__MODULE__, :context}, nil)

    @impl true
    def call_tool(source_id, tool, _args, context) do
      :persistent_term.put({__MODULE__, :context}, context)

      case :ets.lookup(@table, {source_id, tool}) do
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
      assert cap.metadata.mcp_source == "operator:github"
      assert cap.metadata.original_name == "create_issue"
      assert cap.metadata.sanitized_name == "mcp_github_create_issue"
      assert cap.parameters == descriptor.input_schema

      assert {McpCapability, :invoke, [spec]} = cap.executor
      assert spec.source_id == {:operator, "github"}
      assert spec.original == "create_issue"
      assert spec.sanitized == "mcp_github_create_issue"
      assert spec.caller == StubCaller
      assert spec.policy == nil
    end

    test "a plugin-owned server carries its source-qualified identity" do
      descriptor = %{name: "get_note", description: "x", input_schema: %{}}

      cap =
        McpCapability.from_tool_descriptor("eden", descriptor,
          caller: StubCaller,
          source_id: {:plugin, "eden"},
          name_prefix: "eden_"
        )

      assert cap.name == "eden_get_note"
      assert cap.metadata.mcp_source == "plugin:eden"

      assert {McpCapability, :invoke, [%{source_id: {:plugin, "eden"}, plugin: "eden"}]} =
               cap.executor
    end

    test "final_name: bypasses derivation for an already-preflighted signed name" do
      descriptor = %{name: "eden_get_note", description: "x", input_schema: %{}}

      cap =
        McpCapability.from_tool_descriptor("eden", descriptor,
          caller: StubCaller,
          source_id: {:plugin, "eden"},
          final_name: "eden_get_note"
        )

      assert cap.name == "eden_get_note"
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

  describe "invoke/3" do
    test "returns a tool success result on a successful MCP call" do
      descriptor = %{name: "create_issue", description: "x", input_schema: %{}}

      cap = McpCapability.from_tool_descriptor("github", descriptor, caller: StubCaller)

      :ok =
        StubCaller.set_response({:operator, "github"}, "create_issue", {:ok, "issue #42 created"})

      assert {:ok, result} = Capability.execute(cap, %{"title" => "Test"}, %{})
      assert result.success
      assert result.output =~ "issue #42 created"
    end

    test "returns a tool error when the caller returns {:error, reason}" do
      descriptor = %{name: "create_issue", description: "x", input_schema: %{}}

      cap = McpCapability.from_tool_descriptor("github", descriptor, caller: StubCaller)

      :ok =
        StubCaller.set_response({:operator, "github"}, "create_issue", {:error, :unauthorized})

      assert {:ok, result} = Capability.execute(cap, %{"title" => "Test"}, %{})
      refute result.success
      assert result.error =~ "MCP tool 'github/create_issue' failed"
      assert result.error =~ "unauthorized"
    end
  end

  describe "invoke/3 telemetry" do
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

      :ok =
        StubCaller.set_response({:operator, "github"}, "create_issue", {:ok, "issue #42 created"})

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

      :ok =
        StubCaller.set_response({:operator, "github"}, "create_issue", {:error, :unauthorized})

      assert {:ok, result} = Capability.execute(cap, %{}, %{agent_name: "main"})
      refute result.success

      assert_receive {:tool_exec, _measurements, metadata}
      assert metadata.tool == "mcp_github_create_issue"
      assert metadata.success == false
      assert metadata.mcp_server == "github"
      assert metadata.error =~ "unauthorized"
    end

    test "a signed remote call records the redacted correlatable subset only" do
      # "content by default" means the global capture gate OFF. An earlier module
      # can leave it on in this VM, so this test establishes its own precondition.
      previous = Application.get_env(:fermix_core, :telemetry, [])

      Application.put_env(
        :fermix_core,
        :telemetry,
        Keyword.put(previous, :capture_content, false)
      )

      on_exit(fn -> Application.put_env(:fermix_core, :telemetry, previous) end)

      policy = %{
        profile: "retrieval",
        read_only: true,
        replay_safe: false,
        credential_scope: :read,
        resource_scope_kind: :single_workspace
      }

      cap =
        McpCapability.from_tool_descriptor(
          "eden",
          %{name: "eden_get_note", description: "x", input_schema: %{}},
          caller: StubCaller,
          source_id: {:plugin, "eden"},
          final_name: "eden_get_note",
          policy: policy,
          extra_metadata: %{plugin: "eden"}
        )

      :ok = StubCaller.set_response({:plugin, "eden"}, "eden_get_note", {:ok, "note body"})

      context = %{agent_name: "main", session_id: "turn-9"}
      assert {:ok, %{success: true}} = Capability.execute(cap, %{"noteId" => "n1"}, context)

      assert_receive {:tool_exec, _measurements, metadata}
      assert metadata.tool == "eden_get_note"
      assert metadata.plugin == "eden"
      assert metadata.mcp_source == "plugin:eden"
      assert metadata.profile == "retrieval"
      assert metadata.workspace_scope == :single_selected
      assert metadata.read_only == true
      assert metadata.replay_safe == false
      assert metadata.attempt == 1
      # The turn session id correlates; the MCP session id and the workspace id
      # are never recorded, and neither is the note body.
      assert metadata.session_id == "turn-9"
      refute Map.has_key?(metadata, :workspace_id)
      refute Map.has_key?(metadata, :mcp_session_id)
      refute Map.has_key?(metadata, :output)
      refute metadata |> Map.values() |> Enum.any?(&(&1 == "note body"))
    end

    test "model arguments cannot supply or override the invoke context" do
      policy = %{
        profile: "retrieval",
        read_only: true,
        replay_safe: false,
        credential_scope: :read,
        resource_scope_kind: :single_workspace
      }

      cap =
        McpCapability.from_tool_descriptor(
          "eden",
          %{name: "eden_get_note", description: "x", input_schema: %{}},
          caller: StubCaller,
          source_id: {:plugin, "eden"},
          final_name: "eden_get_note",
          policy: policy
        )

      :ok = StubCaller.set_response({:plugin, "eden"}, "eden_get_note", {:ok, "ok"})

      hostile = %{
        "profile" => "capture",
        "source_id" => {:plugin, "other"},
        "read_only" => false,
        "session_id" => "forged",
        "turn_pid" => self()
      }

      assert {:ok, %{success: true}} =
               Capability.execute(cap, hostile, %{agent_name: "main", session_id: "turn-real"})

      invoke_context = StubCaller.last_context()
      assert invoke_context.source_id == {:plugin, "eden"}
      assert invoke_context.profile == "retrieval"
      assert invoke_context.read_only == true
      assert invoke_context.replay_safe == false
      assert invoke_context.session_id == "turn-real"
    end
  end
end
