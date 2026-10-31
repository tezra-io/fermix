defmodule FermixCore.Tools.ChecklistToolsTrustInvariantTest do
  # MILESTONE_85 §11, written as the whole-feature invariant the Known Pitfalls
  # section mandates: no list tool is advertised or executed, and no list line
  # or note is written, on a turn that is not the owner's private turn or voice
  # call; a job reaches a tool only by naming it; and no prompt the turns share
  # names the tools. The family is read from the SEEDER, never spelled out
  # here, so a member added later joins this invariant or fails it.
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Advertisement
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Checklists.Note
  alias FermixCore.Prompt.RuntimeSections
  alias FermixCore.Tools.ScheduleJob

  @family_prefix "checklist_"

  @non_attended [
    {"guest trust",
     %{source_trust: :guest, computer_use_origin: :interactive, chat_type: "private"}},
    {"scheduled run naming no list tool",
     %{
       source_trust: :operator,
       effective_trust: :operator,
       effective_allowed_tools: nil,
       conversation_key: {:scheduled_job, "job_1", "run_1"}
     }},
    {"detached background run", %{source_trust: :operator, computer_use_origin: :unattended}},
    {"delegated subagent",
     %{
       source_trust: :operator,
       computer_use_origin: :interactive,
       chat_type: "private",
       subagent_depth: 1
     }},
    {"coding continuation",
     %{
       source_trust: :operator,
       computer_use_origin: :interactive,
       chat_type: "private",
       harness_continuation_depth: 1
     }},
    {"missing source_trust", %{computer_use_origin: :interactive, chat_type: "private"}}
  ]

  @mention_key {"slack", "C0HALVERING", "1714000000.000100"}

  @shared [
    {"group chat", %{chat_type: "group"}},
    {"Slack channel mention", %{chat_type: "channel", conversation_key: @mention_key}},
    {"Slack mention with no chat type", %{chat_type: nil, conversation_key: @mention_key}},
    {"shared Buzz session",
     %{chat_type: "private", session_env: %{"BUZZ_RELAY_URL" => "wss://relay.invalid"}}}
  ]

  @private [
    {"Telegram private chat", %{chat_type: "private"}},
    {"Slack direct message", %{chat_type: "im", conversation_key: {"slack", "D0ORRIN", :root}}},
    {"paired phone", %{channel: "mobile", conversation_key: {"mobile", "phone-1", :root}}},
    {"Mac app", %{channel: "companion", conversation_key: {"companion", "mac-1", :root}}},
    {"voice call",
     %{
       computer_use_origin: :voice,
       realtime?: true,
       voice_call_id: "root",
       conversation_key: {"realtime", "dev-1", :root}
     }}
  ]

  defp tools, do: BuiltinSeeder.checklist_tool_modules()
  defp capabilities, do: Enum.map(tools(), &Builtin.from_tool_module/1)

  # No store: what is asserted is the gate, which refuses before any read.
  defp base(context) do
    Map.merge(
      %{
        agent_name: "main",
        conversation_key: {"telegram", "40017", :root},
        memory_repo: nil,
        outside_sources: MapSet.new()
      },
      context
    )
  end

  defp owner(context),
    do: base(Map.merge(%{source_trust: :operator, computer_use_origin: :interactive}, context))

  defp advertised(context) do
    capabilities() |> Advertisement.prepare(context) |> Enum.map(& &1.name) |> Enum.sort()
  end

  defp refuses_everything(context, label) do
    for tool <- tools() do
      refute tool.advertise?(context), "#{tool.name()} was advertised on a #{label} turn"
      assert {:ok, result} = tool.execute(%{"changes" => []}, context)
      refute result.success, "#{tool.name()} executed on a #{label} turn"
      assert result.error =~ tool.name()
    end

    assert advertised(context) == []
    assert Note.rules(context, "telegram") == nil
    assert Note.index(context) == nil
  end

  test "the seeder exposes the family and every member is a registered built-in" do
    assert length(tools()) == 2
    assert Enum.all?(tools(), &(&1 in BuiltinSeeder.builtin_tool_modules()))
    assert Enum.all?(tools(), &function_exported?(&1, :advertise?, 1))
    assert Enum.sort(Enum.map(tools(), & &1.name())) == ["checklist_edit", "checklist_read"]
  end

  test "no seeded built-in named checklist_* is missing from the family list" do
    seeded =
      BuiltinSeeder.builtin_tool_modules()
      |> Enum.filter(&String.starts_with?(&1.name(), @family_prefix))
      |> Enum.sort()

    assert seeded == Enum.sort(tools())
  end

  for {label, context} <- @non_attended do
    test "no list tool, line or note on a #{label} turn" do
      refuses_everything(base(unquote(Macro.escape(context))), unquote(label))
    end
  end

  for {label, context} <- @shared do
    test "no list tool, line or note in a #{label}" do
      refuses_everything(owner(unquote(Macro.escape(context))), unquote(label))
    end
  end

  for {label, context} <- @private do
    test "the owner's #{label} is offered both tools and told the list rules" do
      context = owner(unquote(Macro.escape(context)))

      assert advertised(context) == ["checklist_edit", "checklist_read"]

      assert Note.rules(context, Map.get(context, :channel)) =~
               "lives in a list and never in memory"
    end
  end

  test "a job reaches each tool only by naming it, and only at operator trust" do
    job =
      base(%{
        agent_name: "scheduled:job_1",
        conversation_key: {:scheduled_job, "job_1", "run_1"},
        source_trust: :operator,
        effective_trust: :operator,
        effective_allowed_tools: ["checklist_read"]
      })

    assert advertised(job) == ["checklist_read"]

    assert advertised(%{job | effective_allowed_tools: ["checklist_read", "checklist_edit"]}) == [
             "checklist_edit",
             "checklist_read"
           ]

    assert advertised(%{job | effective_trust: :guest}) == []
    assert advertised(Map.put(job, :subagent_depth, 1)) == []

    # A job is told nothing per turn: its prompt is its own.
    assert Note.rules(job, nil) == nil
  end

  test "the capability catalog, cached per profile and shared by group chats, names none of them" do
    for trust <- [:operator, :guest] do
      catalog = RuntimeSections.build([], capabilities: capabilities(), trust: trust)
      refute catalog =~ @family_prefix
    end
  end

  describe "schedule_job gives a job a list tool only from the owner's private turn" do
    defp schedule(context) do
      args = %{
        "name" => "evening_check_in",
        "schedule" => "0 18 * * *",
        "task" => "Read the Projects folder and say what is open.",
        "allowed_tools" => ["checklist_read"]
      }

      {:ok, result} = ScheduleJob.execute(args, context)
      result
    end

    test "a group chat's or a job's request naming one is refused, naming the tool" do
      for context <- [
            owner(%{chat_type: "group"}),
            base(%{
              conversation_key: {:scheduled_job, "job_1", "run_1"},
              source_trust: :operator,
              effective_trust: :operator,
              effective_allowed_tools: ["checklist_read"]
            })
          ] do
        result = schedule(context)
        refute result.success
        assert result.error =~ "checklist_read can be given to a job only from the owner's own"
      end
    end
  end
end
