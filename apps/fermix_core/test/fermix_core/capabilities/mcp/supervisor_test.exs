defmodule FermixCore.Capabilities.MCP.SupervisorTest do
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.MCP.Naming
  alias FermixCore.Capabilities.MCP.Supervisor, as: McpSupervisor
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry

  defmodule StubCaller do
    @behaviour FermixCore.Capabilities.MCP.Caller

    @impl true
    def call_tool(_server, _tool, _args), do: {:ok, "stub-response"}
  end

  defmodule HappyDiscoverer do
    @behaviour FermixCore.Capabilities.MCP.Discoverer

    @impl true
    def list_tools(_client) do
      {:ok,
       [
         %{name: "create_issue", description: "Create issue.", input_schema: %{}},
         %{name: "list_issues", description: "List issues.", input_schema: %{}}
       ]}
    end
  end

  defmodule SadDiscoverer do
    @behaviour FermixCore.Capabilities.MCP.Discoverer

    @impl true
    def list_tools(_client), do: {:error, :transport_closed}
  end

  setup do
    Naming.init()
    suffix = System.unique_integer([:positive])

    cap_registry =
      start_supervised!(
        {CapabilityRegistry, name: :"mcp_sup_cap_reg_#{suffix}"},
        id: :"mcp_sup_cap_reg_child_#{suffix}"
      )

    on_exit(fn ->
      case :ets.whereis(Naming) do
        :undefined -> :ok
        tid -> :ets.delete_all_objects(tid)
      end
    end)

    %{cap_registry: cap_registry, suffix: suffix}
  end

  test "boots a healthy server and exposes its approved tools as capabilities", %{
    cap_registry: cap_registry,
    suffix: suffix
  } do
    {:ok, _} =
      start_supervised(
        {McpSupervisor,
         [
           name: :"mcp_sup_happy_#{suffix}",
           mcp_registry: :"mcp_sup_happy_reg_#{suffix}",
           capability_registry: cap_registry,
           servers: [
             %{
               name: "github",
               approved?: true,
               discoverer: HappyDiscoverer,
               caller: StubCaller
             }
           ]
         ]},
        id: :mcp_supervisor_happy_test
      )

    assert eventually(fn ->
             names =
               cap_registry
               |> CapabilityRegistry.list(kind: :mcp)
               |> Enum.map(& &1.name)
               |> Enum.sort()

             names == ["mcp_github_create_issue", "mcp_github_list_issues"]
           end)
  end

  test "an unhealthy server's restart loop does not bring down healthy peers", %{
    cap_registry: cap_registry,
    suffix: suffix
  } do
    Process.flag(:trap_exit, true)

    sup_name = :"mcp_sup_mixed_#{suffix}"

    {:ok, sup_pid} =
      McpSupervisor.start_link(
        name: sup_name,
        mcp_registry: :"mcp_sup_mixed_reg_#{suffix}",
        capability_registry: cap_registry,
        servers: [
          %{
            name: "github",
            approved?: true,
            discoverer: HappyDiscoverer,
            caller: StubCaller
          },
          %{
            name: "broken",
            approved?: true,
            discoverer: SadDiscoverer,
            caller: StubCaller
          }
        ]
      )

    on_exit(fn ->
      if Process.alive?(sup_pid), do: Process.exit(sup_pid, :shutdown)
    end)

    assert eventually(fn ->
             "mcp_github_create_issue" in cap_names(cap_registry)
           end)

    assert Process.alive?(sup_pid)
    refute Enum.any?(cap_names(cap_registry), &String.starts_with?(&1, "mcp_broken_"))
  end

  defp cap_names(cap_registry) do
    cap_registry
    |> CapabilityRegistry.list(kind: :mcp)
    |> Enum.map(& &1.name)
  end

  defp eventually(fun, deadline_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(20)
        poll(fun, deadline)
      end
    end
  end
end
