defmodule FermixCore.Tools.ToolDescribeTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Tools.ToolDescribe

  defmodule FakeMod do
    def execute(_args, _ctx), do: {:ok, :ok}
  end

  setup do
    name = :"tooldescribe_reg_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: name})

    cap =
      Capability.new(%{
        name: "x_search_posts",
        description: "Search recent X posts (last 7 days).",
        parameters: %{
          "type" => "object",
          "required" => ["query"],
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Search query."},
            "max_results" => %{"type" => "integer", "description" => "Posts to return."}
          }
        },
        kind: :builtin,
        executor: {FakeMod, :execute, []},
        policy_class: :external_api,
        metadata: %{plugin_owned?: true, category: :plugin}
      })

    :ok = CapabilityRegistry.register(name, cap)
    %{registry: name}
  end

  test "renders the full schema for a deferred tool (shared tool_help renderer)", %{
    registry: registry
  } do
    assert {:ok, %{success: true, output: output}} =
             ToolDescribe.execute(%{"name" => "x_search_posts"}, %{capability_registry: registry})

    assert output =~ "# x_search_posts"
    assert output =~ "Search recent X posts"
    assert output =~ "`query` (string, required)"
    assert output =~ "`max_results` (integer, optional)"
  end

  test "unknown names return a corrective error", %{registry: registry} do
    assert {:ok, %{success: false, error: error}} =
             ToolDescribe.execute(%{"name" => "nope_tool"}, %{capability_registry: registry})

    assert error =~ "Unknown capability: nope_tool"
  end
end
