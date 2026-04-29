defmodule FermixCore.Capabilities.BuiltinTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Builtin

  describe "from_tool_module/1" do
    test "wraps Tools.Shell with policy_class :exec" do
      cap = Builtin.from_tool_module(FermixCore.Tools.Shell)

      assert cap.kind == :builtin
      assert cap.name == "shell"
      assert cap.policy_class == :exec
      assert cap.requires_approval? == false
      assert cap.executor == {FermixCore.Tools.Shell, :execute, []}
      assert cap.metadata == %{tool_module: FermixCore.Tools.Shell}
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

    test "wraps Tools.MemoryRecall with policy_class :read_only" do
      cap = Builtin.from_tool_module(FermixCore.Tools.MemoryRecall)
      assert cap.policy_class == :read_only
    end

    test "wraps Tools.MemoryStore with policy_class :read_write" do
      cap = Builtin.from_tool_module(FermixCore.Tools.MemoryStore)
      assert cap.policy_class == :read_write
    end
  end
end
