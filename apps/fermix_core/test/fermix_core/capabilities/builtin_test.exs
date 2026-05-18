defmodule FermixCore.Capabilities.BuiltinTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Builtin

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

    test "wraps scheduled job management tools with expected policy classes" do
      assert Builtin.from_tool_module(FermixCore.Tools.ScheduleJob).policy_class == :read_write
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
        FermixCore.Tools.Delegate,
        FermixCore.Tools.SkillCreate,
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
  end
end
