defmodule FermixCore.Capabilities.BuiltinTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.BuiltinSeeder

  describe "from_tool_module/1" do
    test "wraps Tools.Shell with policy_class :exec" do
      cap = Builtin.from_tool_module(FermixCore.Tools.Shell)

      assert cap.kind == :builtin
      assert cap.name == "shell"
      assert cap.policy_class == :exec
      assert cap.hidden_from_agent? == false
      assert cap.executor == {FermixCore.Tools.Shell, :execute, []}
      assert cap.metadata.tool_module == FermixCore.Tools.Shell
      assert cap.metadata.when_to_use =~ "shell command"
      assert cap.metadata.category == :system
      assert is_list(cap.metadata.examples)
      assert is_list(cap.metadata.failure_modes)
      assert cap.metadata.requires_setup == nil
      assert cap.parameters[:type] == "object"
    end

    test "wraps Tools.FileRead with policy_class :read_only" do
      cap = Builtin.from_tool_module(FermixCore.Tools.FileRead)
      assert cap.policy_class == :read_only
    end

    test "wraps Tools.FileWrite with policy_class :read_write" do
      cap = Builtin.from_tool_module(FermixCore.Tools.FileWrite)
      assert cap.policy_class == :read_write
    end

    test "wraps Tools.Browser with policy_class :network" do
      cap = Builtin.from_tool_module(FermixCore.Tools.Browser)
      assert cap.policy_class == :network
    end

    test "wraps Tools.SendAttachment as the only channel-category builtin" do
      cap = Builtin.from_tool_module(FermixCore.Tools.SendAttachment)

      assert cap.name == "send_attachment"
      assert cap.policy_class == :read_only
      assert cap.hidden_from_agent? == false
      assert cap.metadata.category == :channel
    end

    test "wraps Tools.MemoryRecall with policy_class :read_only" do
      cap = Builtin.from_tool_module(FermixCore.Tools.MemoryRecall)
      assert cap.policy_class == :read_only
    end

    test "wraps Tools.MemoryStore with policy_class :read_write" do
      cap = Builtin.from_tool_module(FermixCore.Tools.MemoryStore)
      assert cap.policy_class == :read_write
    end

    test "wraps skill lifecycle tools as operator-only exec capabilities" do
      assert Builtin.from_tool_module(FermixCore.Tools.SkillView).policy_class == :exec
      assert Builtin.from_tool_module(FermixCore.Tools.SkillRun).policy_class == :exec
    end

    test "wraps scheduled job management tools with expected policy classes" do
      assert Builtin.from_tool_module(FermixCore.Tools.ScheduleJob).policy_class == :read_write
      assert Builtin.from_tool_module(FermixCore.Tools.UpdateJob).policy_class == :read_write
      assert Builtin.from_tool_module(FermixCore.Tools.ListJobs).policy_class == :read_only
      assert Builtin.from_tool_module(FermixCore.Tools.PauseJob).policy_class == :read_write
      assert Builtin.from_tool_module(FermixCore.Tools.ResumeJob).policy_class == :read_write
      assert Builtin.from_tool_module(FermixCore.Tools.RemoveJob).policy_class == :read_write

      assert Builtin.from_tool_module(FermixCore.Tools.MemorySourcesList).policy_class ==
               :read_only
    end

    test "does not mark non-channel builtins as channel tools" do
      tool_modules = [
        FermixCore.Tools.Shell,
        FermixCore.Tools.FileRead,
        FermixCore.Tools.FileWrite,
        FermixCore.Tools.FileEdit,
        FermixCore.Tools.GlobSearch,
        FermixCore.Tools.ContentSearch,
        FermixCore.Tools.GitRead,
        FermixCore.Tools.GitWrite,
        FermixCore.Tools.WebFetch,
        FermixCore.Tools.WebSearch,
        FermixCore.Tools.SkillCreate,
        FermixCore.Tools.SkillView,
        FermixCore.Tools.SkillRun,
        FermixCore.Tools.ModelRoutingConfig,
        FermixCore.Tools.ToolHelp,
        FermixCore.Tools.MemoryStore,
        FermixCore.Tools.MemoryRecall,
        FermixCore.Tools.ScheduleJob,
        FermixCore.Tools.ListJobs,
        FermixCore.Tools.PauseJob,
        FermixCore.Tools.ResumeJob,
        FermixCore.Tools.RemoveJob,
        FermixCore.Tools.MemorySourcesList,
        FermixCore.Tools.Browser
      ]

      names =
        tool_modules
        |> Enum.map(&Builtin.from_tool_module/1)
        |> Enum.filter(&(&1.metadata.category == :channel))
        |> Enum.map(& &1.name)

      assert names == []
    end

    test "every seeded built-in has an explicit policy_class classification" do
      classified = MapSet.new(Builtin.classified_names())

      unclassified =
        BuiltinSeeder.builtin_tool_modules()
        |> Enum.map(& &1.name())
        |> Enum.reject(&MapSet.member?(classified, &1))

      assert unclassified == [],
             "built-ins missing an explicit @policy_defaults entry (would default to " <>
               ":read_only and silently join the subagent surface): #{inspect(unclassified)}"
    end

    # Fail-closed at test time, declarative in one table: a new built-in must
    # state whether it hands back owner data. Without this, `owner_only?`
    # defaults to false and the tool silently joins the guest surface — the
    # same fail-open shape the policy_class guard above exists to prevent.
    test "every seeded built-in declares owner_only? explicitly" do
      undeclared =
        BuiltinSeeder.builtin_tool_modules()
        |> Enum.map(& &1.name())
        |> Enum.reject(&Builtin.owner_only_declared?/1)

      assert undeclared == [],
             "built-ins missing an explicit owner_only? decision (would default to " <>
               "false and silently join the guest surface): #{inspect(undeclared)}"
    end

    test "the tools that return owner data are flagged owner_only?" do
      flagged =
        BuiltinSeeder.builtin_tool_modules()
        |> Enum.map(&Builtin.from_tool_module/1)
        |> Enum.filter(& &1.owner_only?)
        |> Enum.map(& &1.name)
        |> Enum.sort()

      # The event family (MILESTONE_30 §12.1, §20) is owner data by definition —
      # every row is the owner's own calendar.
      assert flagged == [
               "content_search",
               "event_list",
               "event_remove",
               "event_store",
               "event_update",
               "file_read",
               "get_job_run",
               "git_read",
               "glob_search",
               "list_job_runs",
               "list_jobs",
               "memory_sources_list",
               "reminder_snooze"
             ]
    end
  end
end
