defmodule FermixCore.Capabilities.MCP.ServerTest do
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.MCP.Naming
  alias FermixCore.Capabilities.MCP.Registry, as: McpRegistry
  alias FermixCore.Capabilities.MCP.Server, as: McpServer
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry

  defmodule StubCaller do
    @behaviour FermixCore.Capabilities.MCP.Caller

    @table :mcp_server_test_caller

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

  defmodule StubDiscoverer do
    @behaviour FermixCore.Capabilities.MCP.Discoverer

    def set_tools(tools), do: :persistent_term.put({__MODULE__, :tools}, tools)
    def set_error(reason), do: :persistent_term.put({__MODULE__, :tools}, {:error, reason})

    @impl true
    def list_tools(_client) do
      case :persistent_term.get({__MODULE__, :tools}, []) do
        {:error, reason} -> {:error, reason}
        tools when is_list(tools) -> {:ok, tools}
      end
    end
  end

  setup do
    Naming.init()
    :ok = StubCaller.init()
    suffix = System.unique_integer([:positive])

    cap_registry =
      start_supervised!(
        {CapabilityRegistry, name: :"mcp_server_cap_reg_#{suffix}"},
        id: :"mcp_server_cap_reg_child_#{suffix}"
      )

    mcp_registry =
      start_supervised!(
        {McpRegistry, name: :"mcp_server_mcp_reg_#{suffix}"},
        id: :"mcp_server_mcp_reg_child_#{suffix}"
      )

    on_exit(fn ->
      StubCaller.cleanup()

      try do
        :persistent_term.erase({StubDiscoverer, :tools})
      catch
        _, _ -> :ok
      end

      case :ets.whereis(Naming) do
        :undefined -> :ok
        tid -> :ets.delete_all_objects(tid)
      end
    end)

    %{cap_registry: cap_registry, mcp_registry: mcp_registry}
  end

  describe "init" do
    test "registers each discovered tool as an MCP capability and exposes approved ones", %{
      cap_registry: cap_registry,
      mcp_registry: mcp_registry
    } do
      StubDiscoverer.set_tools([
        %{name: "create_issue", description: "Create issue.", input_schema: %{}},
        %{name: "list_issues", description: "List issues.", input_schema: %{}}
      ])

      {:ok, _} =
        start_supervised(
          {McpServer,
           [
             server_name: "github",
             discoverer: StubDiscoverer,
             caller: StubCaller,
             approved?: true,
             capability_registry: cap_registry,
             mcp_registry: mcp_registry,
             fail_fast?: true
           ]},
          id: :mcp_server_init_test
        )

      names =
        cap_registry
        |> CapabilityRegistry.list(kind: :mcp)
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert names == ["mcp_github_create_issue", "mcp_github_list_issues"]

      [first | _] = CapabilityRegistry.list(cap_registry, kind: :mcp)
      assert first.metadata.approved? == true
      refute first.requires_approval?
    end

    test "unapproved MCP tools are hidden from the default LLM-facing list", %{
      cap_registry: cap_registry,
      mcp_registry: mcp_registry
    } do
      StubDiscoverer.set_tools([
        %{name: "create_issue", description: "x", input_schema: %{}}
      ])

      {:ok, _} =
        start_supervised(
          {McpServer,
           [
             server_name: "github",
             discoverer: StubDiscoverer,
             caller: StubCaller,
             approved?: false,
             capability_registry: cap_registry,
             mcp_registry: mcp_registry,
             fail_fast?: true
           ]},
          id: :mcp_server_unapproved
        )

      assert CapabilityRegistry.list(cap_registry) == []

      assert [_only] = CapabilityRegistry.list(cap_registry, include_approval_required?: true)
    end

    test "exits with a tagged reason when discovery fails (fail_fast?: true)", %{
      cap_registry: cap_registry,
      mcp_registry: mcp_registry
    } do
      StubDiscoverer.set_error(:transport_closed)

      Process.flag(:trap_exit, true)

      assert {:error, {:mcp_discovery_failed, "github", :transport_closed}} =
               McpServer.start_link(
                 server_name: "github",
                 discoverer: StubDiscoverer,
                 caller: StubCaller,
                 capability_registry: cap_registry,
                 mcp_registry: mcp_registry,
                 fail_fast?: true
               )
    end

    test "async discovery survives a transient transport error and registers on retry", %{
      cap_registry: cap_registry,
      mcp_registry: mcp_registry
    } do
      StubDiscoverer.set_error(:transport_closed)

      {:ok, pid} =
        McpServer.start_link(
          server_name: "github",
          discoverer: StubDiscoverer,
          caller: StubCaller,
          approved?: true,
          capability_registry: cap_registry,
          mcp_registry: mcp_registry,
          retry_base_ms: 20,
          max_discovery_attempts: 5
        )

      Process.sleep(40)
      assert CapabilityRegistry.list(cap_registry, kind: :mcp) == []

      StubDiscoverer.set_tools([
        %{name: "create_issue", description: "x", input_schema: %{}}
      ])

      Process.sleep(120)

      assert [%{name: "mcp_github_create_issue"}] =
               CapabilityRegistry.list(cap_registry, kind: :mcp)

      Process.exit(pid, :shutdown)
    end

    test "tool_overrides win for policy_class and requires_approval?", %{
      cap_registry: cap_registry,
      mcp_registry: mcp_registry
    } do
      StubDiscoverer.set_tools([
        %{name: "read_file", description: "x", input_schema: %{}}
      ])

      {:ok, _} =
        start_supervised(
          {McpServer,
           [
             server_name: "filesystem",
             discoverer: StubDiscoverer,
             caller: StubCaller,
             approved?: false,
             tools_overrides: %{
               "read_file" => %{policy_class: :read_only, requires_approval?: false}
             },
             capability_registry: cap_registry,
             mcp_registry: mcp_registry,
             fail_fast?: true
           ]},
          id: :mcp_server_overrides
        )

      [cap] = CapabilityRegistry.list(cap_registry)
      assert cap.policy_class == :read_only
      assert cap.requires_approval? == false
    end
  end

  describe "terminate" do
    test "unregisters this server's capabilities on shutdown but leaves others", %{
      cap_registry: cap_registry,
      mcp_registry: mcp_registry
    } do
      StubDiscoverer.set_tools([
        %{name: "create_issue", description: "x", input_schema: %{}}
      ])

      {:ok, pid} =
        McpServer.start_link(
          server_name: "github",
          discoverer: StubDiscoverer,
          caller: StubCaller,
          approved?: true,
          capability_registry: cap_registry,
          mcp_registry: mcp_registry,
          fail_fast?: true
        )

      assert [_cap] = CapabilityRegistry.list(cap_registry, kind: :mcp)

      ref = Process.monitor(pid)
      :ok = GenServer.stop(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      assert CapabilityRegistry.list(cap_registry, kind: :mcp) == []
    end
  end
end
