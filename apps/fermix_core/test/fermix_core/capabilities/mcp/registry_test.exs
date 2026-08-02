defmodule FermixCore.Capabilities.MCP.RegistryTest do
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.MCP.Registry, as: McpRegistry

  setup do
    suffix = System.unique_integer([:positive])

    registry =
      start_supervised!(
        {McpRegistry, name: :"mcp_registry_test_#{suffix}"},
        id: :"mcp_registry_test_child_#{suffix}"
      )

    %{registry: registry}
  end

  defp idle_process do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  describe "source-qualified keys" do
    test "a plugin and an operator server with the same name never collide", %{
      registry: registry
    } do
      plugin_client = idle_process()
      operator_client = idle_process()

      :ok = McpRegistry.register(registry, {:plugin, "eden"}, plugin_client)
      :ok = McpRegistry.register(registry, {:operator, "eden"}, operator_client)

      assert {:ok, ^plugin_client} = McpRegistry.lookup_client(registry, {:plugin, "eden"})
      assert {:ok, ^operator_client} = McpRegistry.lookup_client(registry, {:operator, "eden"})
    end

    test "unregistering one source leaves the other intact", %{registry: registry} do
      plugin_client = idle_process()
      operator_client = idle_process()

      :ok = McpRegistry.register(registry, {:plugin, "eden"}, plugin_client)
      :ok = McpRegistry.register(registry, {:operator, "eden"}, operator_client)
      :ok = McpRegistry.unregister(registry, {:plugin, "eden"})

      assert {:error, :not_found} = McpRegistry.lookup_client(registry, {:plugin, "eden"})
      assert {:ok, ^operator_client} = McpRegistry.lookup_client(registry, {:operator, "eden"})
    end

    test "a dead client is dropped", %{registry: registry} do
      client = idle_process()
      :ok = McpRegistry.register(registry, {:operator, "fs"}, client)

      ref = Process.monitor(client)
      Process.exit(client, :kill)
      assert_receive {:DOWN, ^ref, :process, ^client, :killed}

      # One synchronous round-trip after the :DOWN reaches the registry.
      _ = McpRegistry.lookup_client(registry, {:operator, "other"})
      Process.sleep(20)
      assert {:error, :not_found} = McpRegistry.lookup_client(registry, {:operator, "fs"})
    end
  end

  describe "the raw remote client is private" do
    test "a remote source publishes only its proxy", %{registry: registry} do
      proxy = idle_process()
      :ok = McpRegistry.register_proxy(registry, {:plugin, "eden"}, proxy)

      assert {:ok, ^proxy} = McpRegistry.lookup_proxy(registry, {:plugin, "eden"})
      assert {:error, :client_private} = McpRegistry.lookup_client(registry, {:plugin, "eden"})
    end

    test "a stdio source publishes no proxy", %{registry: registry} do
      client = idle_process()
      :ok = McpRegistry.register(registry, {:operator, "fs"}, client)

      assert {:error, :not_found} = McpRegistry.lookup_proxy(registry, {:operator, "fs"})
    end

    test "an unknown source is not found either way", %{registry: registry} do
      assert {:error, :not_found} = McpRegistry.lookup_client(registry, {:plugin, "nope"})
      assert {:error, :not_found} = McpRegistry.lookup_proxy(registry, {:plugin, "nope"})
    end
  end
end
