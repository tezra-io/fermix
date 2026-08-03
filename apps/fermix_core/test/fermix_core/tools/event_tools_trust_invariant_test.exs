defmodule FermixCore.Tools.EventToolsTrustInvariantTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Advertisement
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.BuiltinSeeder

  # MILESTONE_30 §12.1 / §14 / §20, written as the whole-feature invariant the
  # Known Pitfalls section mandates: NO tool in the temporal family may be
  # advertised or executed on a non-attended turn. The tool list is read from the
  # SEEDER, never spelled out here, so a family member added later either joins
  # this invariant or fails it.
  #
  # The family spans two name prefixes — the `event_*` tools that own stored
  # events and the `reminder_*` tools that act on their concrete reminder rows —
  # so the completeness check below keys on BOTH. A snooze-family tool named
  # outside `event_*` must not be able to sit outside the gate.
  @family_prefixes ["event_", "reminder_"]

  @non_attended [
    {"guest trust", %{source_trust: :guest, computer_use_origin: :interactive}},
    {"scheduled run (no origin marker)", %{source_trust: :operator}},
    {"detached background run", %{source_trust: :operator, computer_use_origin: :unattended}},
    {"delegated subagent",
     %{source_trust: :operator, computer_use_origin: :interactive, subagent_depth: 1}},
    {"coding continuation",
     %{source_trust: :operator, computer_use_origin: :interactive, harness_continuation_depth: 1}},
    {"missing source_trust", %{computer_use_origin: :interactive}}
  ]

  @attended %{source_trust: :operator, computer_use_origin: :interactive}

  defp event_tools, do: BuiltinSeeder.event_tool_modules()

  defp base(context),
    do: Map.merge(%{agent_name: "main", conversation_key: {"cli", "1", :root}}, context)

  test "the seeder exposes the event family and every member is a registered built-in" do
    tools = event_tools()

    refute Enum.empty?(tools)
    assert Enum.all?(tools, &(&1 in BuiltinSeeder.builtin_tool_modules()))
    assert Enum.all?(tools, &function_exported?(&1, :advertise?, 1))
  end

  # The other direction: a family tool seeded without joining the family list
  # would silently sit outside every gate assertion below.
  test "no seeded built-in named event_* or reminder_* is missing from the family list" do
    seeded =
      BuiltinSeeder.builtin_tool_modules()
      |> Enum.filter(fn module ->
        Enum.any?(@family_prefixes, &String.starts_with?(module.name(), &1))
      end)
      |> Enum.sort()

    assert seeded == Enum.sort(event_tools())
  end

  test "the family covers both of its name prefixes" do
    names = Enum.map(event_tools(), & &1.name())

    for prefix <- @family_prefixes do
      assert Enum.any?(names, &String.starts_with?(&1, prefix)),
             "no #{prefix}* tool is in the family list"
    end

    assert "reminder_snooze" in names
  end

  for {label, context} <- @non_attended do
    test "no event tool is advertised or executable on a #{label} turn" do
      context = base(unquote(Macro.escape(context)))

      for tool <- event_tools() do
        refute tool.advertise?(context),
               "#{tool.name()} was advertised on a #{unquote(label)} turn"

        assert {:ok, result} = tool.execute(%{}, context)
        refute result.success, "#{tool.name()} executed on a #{unquote(label)} turn"
        assert result.error =~ tool.name()
      end
    end

    test "the provider-visible surface drops the whole event family on a #{label} turn" do
      context = base(unquote(Macro.escape(context)))
      capabilities = Enum.map(event_tools(), &Builtin.from_tool_module/1)

      assert Advertisement.prepare(capabilities, context) == []
    end
  end

  test "an attended top-level operator turn advertises the whole event family" do
    context = base(@attended)
    capabilities = Enum.map(event_tools(), &Builtin.from_tool_module/1)

    assert Enum.all?(event_tools(), & &1.advertise?(context))
    assert length(Advertisement.prepare(capabilities, context)) == length(event_tools())
  end

  test "every event tool declares owner-only capability metadata" do
    for tool <- event_tools() do
      capability = Builtin.from_tool_module(tool)

      assert capability.owner_only? == true, "#{tool.name()} is not owner-only"
      assert Builtin.owner_only_declared?(tool.name())
      assert capability.policy_class in [:read_only, :read_write]
      assert tool.category() == :scheduling
    end
  end

  test "only event_list is read-only; the mutating tools are read_write" do
    classes =
      Map.new(event_tools(), fn tool ->
        {tool.name(), Builtin.from_tool_module(tool).policy_class}
      end)

    assert classes["event_list"] == :read_only

    assert Enum.all?(Map.drop(classes, ["event_list"]), fn {_name, class} ->
             class == :read_write
           end)
  end
end
