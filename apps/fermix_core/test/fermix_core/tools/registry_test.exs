defmodule FermixCore.Tools.RegistryTest do
  use ExUnit.Case, async: true

  alias FermixCore.Tools.Registry
  alias FermixCore.Tools.Tool

  # Fake tools for testing registration
  defmodule ToolA do
    @behaviour Tool

    @impl true
    def name, do: "tool_a"
    @impl true
    def description, do: "Tool A for testing"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}
    @impl true
    def execute(_args, _ctx), do: {:ok, Tool.success("a")}
  end

  defmodule ToolB do
    @behaviour Tool

    @impl true
    def name, do: "tool_b"
    @impl true
    def description, do: "Tool B for testing"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}
    @impl true
    def execute(_args, _ctx), do: {:ok, Tool.success("b")}
  end

  setup do
    registry = start_supervised!({Registry, name: :"registry_#{System.unique_integer()}"})
    %{registry: registry}
  end

  describe "all_tools/1" do
    test "returns empty list when no tools registered", %{registry: registry} do
      assert Registry.all_tools(registry) == []
    end

    test "returns registered tools", %{registry: registry} do
      :ok = Registry.register(registry, ToolA)
      assert Registry.all_tools(registry) == [ToolA]
    end

    test "returns all registered tools in registration order", %{registry: registry} do
      :ok = Registry.register(registry, ToolA)
      :ok = Registry.register(registry, ToolB)
      assert Registry.all_tools(registry) == [ToolA, ToolB]
    end
  end

  describe "register/2" do
    test "registers a tool module", %{registry: registry} do
      assert :ok = Registry.register(registry, ToolA)
      assert [ToolA] = Registry.all_tools(registry)
    end

    test "rejects duplicate registration", %{registry: registry} do
      :ok = Registry.register(registry, ToolA)
      assert {:error, :already_registered} = Registry.register(registry, ToolA)
    end
  end

  describe "find_tool/2" do
    test "finds a registered tool by name", %{registry: registry} do
      :ok = Registry.register(registry, ToolA)
      assert {:ok, ToolA} = Registry.find_tool(registry, "tool_a")
    end

    test "returns error for unknown tool", %{registry: registry} do
      assert :error = Registry.find_tool(registry, "nonexistent")
    end
  end

  describe "find_tool/3 with allowlist" do
    test "finds a registered tool when it is allowed", %{registry: registry} do
      :ok = Registry.register(registry, ToolA)

      assert {:ok, ToolA} = Registry.find_tool(registry, "tool_a", ["tool_a"])
    end

    test "returns not_allowed when tool is registered but excluded", %{registry: registry} do
      :ok = Registry.register(registry, ToolA)

      assert {:error, :not_allowed} = Registry.find_tool(registry, "tool_a", ["tool_b"])
    end
  end

  describe "all_tools_for_llm/1" do
    test "returns empty list when no tools registered", %{registry: registry} do
      assert Registry.all_tools_for_llm(registry) == []
    end

    test "formats all registered tools for LLM consumption", %{registry: registry} do
      :ok = Registry.register(registry, ToolA)

      assert [formatted] = Registry.all_tools_for_llm(registry)
      assert formatted.type == "function"
      assert formatted.function.name == "tool_a"
      assert formatted.function.description == "Tool A for testing"
    end

    test "filters tools to the allowlist", %{registry: registry} do
      :ok = Registry.register(registry, ToolA)
      :ok = Registry.register(registry, ToolB)

      assert [formatted] = Registry.all_tools_for_llm(registry, ["tool_b"])
      assert formatted.function.name == "tool_b"
    end
  end
end
