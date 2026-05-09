defmodule FermixCore.Tools.ToolHelpTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Registry
  alias FermixCore.Tools.ContentSearch
  alias FermixCore.Tools.ToolHelp

  @context %{agent_name: "test_agent", conversation_key: :test}

  test "returns full docs for a registered capability" do
    name = :"tool_help_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: name})
    :ok = Registry.register(name, Builtin.from_tool_module(ContentSearch))

    assert {:ok, result} =
             ToolHelp.execute(
               %{"name" => "content_search"},
               Map.put(@context, :capability_registry, name)
             )

    assert result.success == true
    assert result.output =~ "# content_search"
    assert result.output =~ "## Parameters"
    assert result.output =~ "## Examples"
    assert result.output =~ "## Failure modes"
    assert result.output =~ "`pattern`"
  end

  test "returns a clear error for an unknown capability" do
    name = :"tool_help_missing_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: name})

    assert {:ok, result} =
             ToolHelp.execute(
               %{"name" => "missing"},
               Map.put(@context, :capability_registry, name)
             )

    assert result.success == false
    assert result.error =~ "Unknown capability"
  end
end
