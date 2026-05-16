defmodule FermixCore.MCP.Inbound.CapabilityPortTest do
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry
  alias FermixCore.MCP.Inbound.CapabilityPort
  alias FermixCore.MCP.Inbound.CapabilityPort.Local

  defmodule ProbeExecutor do
    def execute(args, context) do
      send(context.test_pid, {:probe_executed, args, context})
      {:ok, %{success: true, output: "probe-ok", error: nil}}
    end
  end

  setup do
    suffix = System.unique_integer([:positive])

    registry =
      start_supervised!(
        {Registry, name: :"inbound_port_registry_#{suffix}"},
        id: :"inbound_port_registry_child_#{suffix}"
      )

    previous_registry = Application.get_env(:fermix_core, :mcp_inbound_capability_registry)
    previous_port = Application.get_env(:fermix_core, :mcp_inbound_capability_port)

    Application.put_env(:fermix_core, :mcp_inbound_capability_registry, registry)

    on_exit(fn ->
      restore_env(:mcp_inbound_capability_registry, previous_registry)
      restore_env(:mcp_inbound_capability_port, previous_port)
    end)

    %{registry: registry}
  end

  test "impl/0 defaults to the local port" do
    Application.delete_env(:fermix_core, :mcp_inbound_capability_port)

    assert CapabilityPort.impl() == Local
  end

  test "local port lists approval-required capabilities for inbound filtering", %{
    registry: registry
  } do
    :ok = Registry.register(registry, capability("needs_approval", requires_approval?: true))

    assert {:ok, [%Capability{name: "needs_approval"}]} = Local.list_capabilities()
  end

  test "local port executes by capability name with explicit context", %{registry: registry} do
    :ok = Registry.register(registry, capability("probe"))

    assert {:ok, %{success: true, output: "probe-ok"}} =
             Local.execute_capability("probe", %{"input" => "value"}, %{test_pid: self()})

    assert_receive {:probe_executed, %{"input" => "value"}, %{test_pid: pid}}
    assert pid == self()
  end

  defp capability(name, opts \\ []) do
    Capability.new(%{
      name: name,
      description: "Probe capability",
      parameters: %{
        type: "object",
        properties: %{input: %{type: "string"}}
      },
      kind: Keyword.get(opts, :kind, :builtin),
      executor: {ProbeExecutor, :execute, []},
      requires_approval?: Keyword.get(opts, :requires_approval?, false),
      policy_class: Keyword.get(opts, :policy_class, :read_only)
    })
  end

  defp restore_env(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore_env(key, value), do: Application.put_env(:fermix_core, key, value)
end
