defmodule FermixCore.Tools.OpenLoopToolsTrustInvariantTest do
  # async: false — the whole-surface gate reads `[fermix_core.open_loops]
  # enabled` from global `Application` env, which each test pins and restores.
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.Advertisement
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.OpenLoops.CheckIn
  alias FermixCore.Prompt.RuntimeSections

  # MILESTONE_78 §08, §10 and §18, written as the whole-feature invariant the
  # Known Pitfalls section mandates: no open-loop tool is advertised or executed
  # on a turn that is not an attended owner turn, the check-in run reaches only
  # its own two, the main turn never reaches the check-in's outcome tool, and a
  # disabled install advertises none of them anywhere. The tool list is read
  # from the SEEDER, never spelled out here, so a member added later either
  # joins this invariant or fails it.
  @family_prefix "open_loop_"

  # The check-in run's context is built by the module that runs it, never
  # copied here: if a later edit gives that context an attended-origin marker,
  # or drops the `open_loop_checkin` key, this invariant fails instead of
  # quietly handing a detached model run the tools that note and settle loops.
  # Invented values.
  @checkin_loop %{
    id: "loop_Wd7tR2pLx0e",
    agent_id: "main",
    owner_id: "default",
    delivery_platform: "cli",
    delivery_destination: "owner-terminal",
    delivery_thread_scope: "root"
  }

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

  setup do
    previous = Application.get_env(:fermix_core, :open_loops)
    Application.put_env(:fermix_core, :open_loops, enabled: true)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fermix_core, :open_loops)
        value -> Application.put_env(:fermix_core, :open_loops, value)
      end
    end)

    :ok
  end

  defp open_loop_tools, do: BuiltinSeeder.open_loop_tool_modules()

  defp checkin do
    CheckIn.loop_context(%{loop: @checkin_loop, touch: 1, repo: :unused_repo, ref: make_ref()})
  end

  defp capabilities, do: Enum.map(open_loop_tools(), &Builtin.from_tool_module/1)

  defp base(context),
    do: Map.merge(%{agent_name: "main", conversation_key: {"telegram", "40017", :root}}, context)

  defp advertised(context) do
    capabilities() |> Advertisement.prepare(context) |> Enum.map(& &1.name) |> Enum.sort()
  end

  defp disable, do: Application.put_env(:fermix_core, :open_loops, enabled: false)

  test "the seeder exposes the family and every member is a registered built-in" do
    tools = open_loop_tools()

    assert length(tools) == 4
    assert Enum.all?(tools, &(&1 in BuiltinSeeder.builtin_tool_modules()))
    assert Enum.all?(tools, &function_exported?(&1, :advertise?, 1))
  end

  # The other direction: a family tool seeded without joining the family list
  # would silently sit outside every gate assertion below.
  test "no seeded built-in named open_loop_* is missing from the family list" do
    seeded =
      BuiltinSeeder.builtin_tool_modules()
      |> Enum.filter(&String.starts_with?(&1.name(), @family_prefix))
      |> Enum.sort()

    assert seeded == Enum.sort(open_loop_tools())
  end

  for {label, context} <- @non_attended do
    test "no open-loop tool is advertised or executed on a #{label} turn" do
      context = base(unquote(Macro.escape(context)))

      for tool <- open_loop_tools() do
        refute tool.advertise?(context),
               "#{tool.name()} was advertised on a #{unquote(label)} turn"

        assert {:ok, result} = tool.execute(%{}, context)
        refute result.success, "#{tool.name()} executed on a #{unquote(label)} turn"
        assert result.error =~ tool.name()
      end

      assert advertised(context) == []
    end
  end

  test "an attended owner turn is offered the three main tools and never the outcome tool" do
    context = base(@attended)

    assert advertised(context) == ["open_loop_list", "open_loop_note", "open_loop_update"]

    respond = Enum.find(open_loop_tools(), &(&1.name() == "open_loop_respond"))
    assert {:ok, result} = respond.execute(%{"decision" => "silent"}, context)
    refute result.success
    assert result.error =~ "open_loop_respond"
  end

  test "a check-in run is offered exactly open_loop_list and open_loop_respond" do
    context = checkin()
    assert advertised(context) == ["open_loop_list", "open_loop_respond"]

    for tool <- open_loop_tools(), tool.name() in ["open_loop_note", "open_loop_update"] do
      assert {:ok, result} = tool.execute(%{}, context)
      refute result.success, "#{tool.name()} executed inside a check-in run"
      assert result.error =~ tool.name()
    end

    respond = Enum.find(open_loop_tools(), &(&1.name() == "open_loop_respond"))
    assert {:ok, %{success: true}} = respond.execute(%{"decision" => "silent"}, context)

    ref = context.open_loop_checkin.ref
    assert_received {:open_loop_respond, ^ref, %{decision: :silent}}
  end

  test "an attended turn that somehow carries the check-in key cannot note or settle" do
    context = Map.merge(base(@attended), Map.take(checkin(), [:open_loop_checkin]))

    refute "open_loop_note" in advertised(context)
    refute "open_loop_update" in advertised(context)
  end

  describe "the whole-surface gate (§10)" do
    test "disabled, no open-loop tool is advertised on an attended owner turn" do
      disable()

      assert advertised(base(@attended)) == []
      assert advertised(checkin()) == []
    end

    test "disabled, every open-loop tool refuses to execute, naming itself" do
      disable()

      for context <- [base(@attended), checkin()], tool <- open_loop_tools() do
        assert {:ok, result} = tool.execute(%{}, context)
        refute result.success, "#{tool.name()} executed while disabled"
        assert result.error =~ tool.name()
        assert result.error =~ "turned off"
      end
    end

    test "disabled, the capability catalog names none of them" do
      disable()

      catalog = RuntimeSections.build([], capabilities: capabilities())

      refute catalog =~ @family_prefix
    end

    test "enabled, the catalog names the three main tools and never the outcome tool" do
      catalog = RuntimeSections.build([], capabilities: capabilities())

      for name <- ["open_loop_note", "open_loop_update", "open_loop_list"] do
        assert catalog =~ "- `#{name}` —"
      end

      refute catalog =~ "open_loop_respond"
    end
  end

  test "every open-loop tool declares owner-only scheduling metadata" do
    for tool <- open_loop_tools() do
      capability = Builtin.from_tool_module(tool)

      assert capability.owner_only? == true, "#{tool.name()} is not owner-only"
      assert Builtin.owner_only_declared?(tool.name())
      assert capability.hidden_from_agent? == false
      assert tool.category() == :scheduling
      assert tool.requires_setup() == nil
    end
  end

  test "only open_loop_list is read-only; the others are read_write" do
    classes =
      Map.new(open_loop_tools(), fn tool ->
        {tool.name(), Builtin.from_tool_module(tool).policy_class}
      end)

    assert classes == %{
             "open_loop_list" => :read_only,
             "open_loop_note" => :read_write,
             "open_loop_respond" => :read_write,
             "open_loop_update" => :read_write
           }
  end
end
