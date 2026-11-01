defmodule FermixCore.Tools.ToolHelpTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry
  alias FermixCore.Tools.ContentSearch
  alias FermixCore.Tools.ToolHelp

  @context %{agent_name: "test_agent", conversation_key: :test}

  # A tool whose words are only known once the daemon runs, so a turn reads them
  # through `dynamic_description/1` rather than the copy registered at boot.
  defmodule DescribedTool do
    @spec dynamic_description(map()) :: String.t()
    def dynamic_description(context) when is_map(context),
      do: "Described for #{Map.fetch!(context, :agent_name)}."

    @spec execute(map(), map()) :: {:ok, map()}
    def execute(_args, _context), do: {:ok, %{success: true, output: "unused"}}
  end

  defp described_capability do
    Capability.new(%{
      name: "described_tool",
      description: "Registered at boot.",
      parameters: %{"type" => "object", "properties" => %{}},
      kind: :builtin,
      executor: {DescribedTool, :execute, []},
      policy_class: :read_only
    })
  end

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

  # The docs say what a turn is told, not what was registered before the daemon
  # knew it: the same hook `Capabilities.Advertisement` refreshes a turn with.
  test "renders a tool's per-turn description when it has one" do
    name = :"tool_help_described_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: name})
    :ok = Registry.register(name, described_capability())

    assert {:ok, result} =
             ToolHelp.execute(
               %{"name" => "described_tool"},
               Map.put(@context, :capability_registry, name)
             )

    assert result.output =~ "Described for test_agent."
    refute result.output =~ "Registered at boot."
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

  # Discovery must match execution. `Registry.find/2` is a raw ETS lookup, so
  # without a ceiling check a guest could read the full schema of a tool it can
  # never call — and `content_search` is `:read_only`, so a policy-class check
  # alone would still admit it.
  test "a guest cannot read the docs of an owner-only capability" do
    name = :"tool_help_guest_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: name})
    :ok = Registry.register(name, Builtin.from_tool_module(ContentSearch))

    context =
      @context
      |> Map.put(:capability_registry, name)
      |> Map.put(:source_trust, :guest)
      |> Map.put(:effective_policy, [:read_only])

    assert {:ok, result} = ToolHelp.execute(%{"name" => "content_search"}, context)

    assert result.success == false
    assert result.error =~ "Unknown capability"
    refute result.error =~ "pattern"
  end

  test "a guest cannot read the docs of a capability outside its policy classes" do
    name = :"tool_help_class_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: name})
    :ok = Registry.register(name, Builtin.from_tool_module(FermixCore.Tools.Shell))

    context =
      @context
      |> Map.put(:capability_registry, name)
      |> Map.put(:source_trust, :guest)
      |> Map.put(:effective_policy, [:read_only])

    assert {:ok, result} = ToolHelp.execute(%{"name" => "shell"}, context)

    assert result.success == false
    assert result.error =~ "Unknown capability"
  end

  test "an operator reads the docs of an owner-only capability unchanged" do
    name = :"tool_help_operator_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: name})
    :ok = Registry.register(name, Builtin.from_tool_module(ContentSearch))

    context =
      @context
      |> Map.put(:capability_registry, name)
      |> Map.put(:source_trust, :operator)

    assert {:ok, result} = ToolHelp.execute(%{"name" => "content_search"}, context)

    assert result.success == true
    assert result.output =~ "# content_search"
  end

  # The run's trust, not its person's: a plugin skill's worker runs at guest
  # under the owner's turn (`CapabilityRegistry.run_trust/1`).
  test "a run at guest trust under the owner cannot read an owner-only capability's docs" do
    name = :"tool_help_run_trust_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: name})
    :ok = Registry.register(name, Builtin.from_tool_module(ContentSearch))

    context =
      @context
      |> Map.put(:capability_registry, name)
      |> Map.merge(%{source_trust: :operator, effective_trust: :guest})

    assert {:ok, result} = ToolHelp.execute(%{"name" => "content_search"}, context)
    assert result.success == false
    assert result.error =~ "Unknown capability"
  end
end
