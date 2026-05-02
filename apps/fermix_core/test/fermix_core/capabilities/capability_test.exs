defmodule FermixCore.Capabilities.CapabilityTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Capability

  defmodule FakeExecutor do
    def echo(args, context, suffix) do
      {:ok, %{args: args, context: context, suffix: suffix}}
    end

    def no_extra(args, context) do
      {:ok, %{args: args, context: context}}
    end
  end

  describe "new/1" do
    test "builds a capability with required + default fields" do
      cap =
        Capability.new(%{
          name: "echo",
          description: "echo back",
          parameters: %{type: "object"},
          kind: :builtin,
          executor: {FakeExecutor, :no_extra, []}
        })

      assert cap.name == "echo"
      assert cap.kind == :builtin
      assert cap.requires_approval? == false
      assert cap.policy_class == :read_only
      assert cap.metadata == %{}
    end

    test "honors policy_class, requires_approval?, metadata overrides" do
      cap =
        Capability.new(%{
          name: "shell",
          description: "shell",
          parameters: %{type: "object"},
          kind: :builtin,
          executor: {FakeExecutor, :no_extra, []},
          policy_class: :exec,
          requires_approval?: true,
          metadata: %{source: :test}
        })

      assert cap.policy_class == :exec
      assert cap.requires_approval? == true
      assert cap.metadata == %{source: :test}
    end

    test "raises on missing required field" do
      assert_raise ArgumentError, ~r/missing required field :name/, fn ->
        Capability.new(%{
          description: "x",
          parameters: %{},
          kind: :builtin,
          executor: {FakeExecutor, :no_extra, []}
        })
      end
    end

    test "raises on invalid kind" do
      assert_raise ArgumentError, ~r/Capability kind must be one of/, fn ->
        Capability.new(%{
          name: "x",
          description: "x",
          parameters: %{},
          kind: :bogus,
          executor: {FakeExecutor, :no_extra, []}
        })
      end
    end

    test "raises on invalid policy_class" do
      assert_raise ArgumentError, ~r/policy_class must be one of/, fn ->
        Capability.new(%{
          name: "x",
          description: "x",
          parameters: %{},
          kind: :builtin,
          executor: {FakeExecutor, :no_extra, []},
          policy_class: :destructive
        })
      end
    end

    test "raises on invalid executor shape" do
      assert_raise ArgumentError, ~r/executor must be \{module, function, extra_args\}/, fn ->
        Capability.new(%{
          name: "x",
          description: "x",
          parameters: %{},
          kind: :builtin,
          executor: {FakeExecutor, :no_extra}
        })
      end
    end

    test "raises on non-string name" do
      assert_raise ArgumentError, ~r/name must be a non-empty string/, fn ->
        Capability.new(%{
          name: nil,
          description: "x",
          parameters: %{},
          kind: :builtin,
          executor: {FakeExecutor, :no_extra, []}
        })
      end
    end
  end

  describe "execute/3" do
    test "dispatches to {mod, fun, []} with [args, context]" do
      cap =
        Capability.new(%{
          name: "echo",
          description: "x",
          parameters: %{},
          kind: :builtin,
          executor: {FakeExecutor, :no_extra, []}
        })

      assert {:ok, %{args: %{"a" => 1}, context: %{agent_name: "main"}}} =
               Capability.execute(cap, %{"a" => 1}, %{agent_name: "main"})
    end

    test "appends extra_args after [args, context]" do
      cap =
        Capability.new(%{
          name: "echo",
          description: "x",
          parameters: %{},
          kind: :skill,
          executor: {FakeExecutor, :echo, ["bonus"]}
        })

      assert {:ok, %{args: %{}, context: %{}, suffix: "bonus"}} =
               Capability.execute(cap, %{}, %{})
    end
  end
end
