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
      assert cap.hidden_from_agent? == false
      assert cap.policy_class == :read_only
      assert cap.metadata == %{}
    end

    test "honors policy_class, hidden_from_agent?, metadata overrides" do
      cap =
        Capability.new(%{
          name: "shell",
          description: "shell",
          parameters: %{type: "object"},
          kind: :builtin,
          executor: {FakeExecutor, :no_extra, []},
          policy_class: :exec,
          hidden_from_agent?: true,
          metadata: %{source: :test}
        })

      assert cap.policy_class == :exec
      assert cap.hidden_from_agent? == true
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

    # The access gate sits at this one boundary: a held call returns the gate's
    # result and the executor is never applied.
    test "a flagged capability in a context with no owner never calls its executor" do
      cap =
        Capability.new(%{
          name: "tesla_unlock_doors",
          description: "x",
          parameters: %{},
          kind: :mcp,
          policy_class: :external_api,
          metadata: %{access_sensitive?: true, plugin_owned?: true, plugin: "tesla"},
          executor: {FakeExecutor, :no_extra, []}
        })

      assert {:ok, %{success: false, error: error}} =
               Capability.execute(cap, %{"vin" => "V"}, %{agent_name: "worker", subagent_depth: 1})

      assert error =~ "not sent"
    end

    test "a flagged capability in a tainted context never calls its executor" do
      cap =
        Capability.new(%{
          name: "tesla_unlock_doors",
          description: "x",
          parameters: %{},
          kind: :mcp,
          policy_class: :external_api,
          metadata: %{access_sensitive?: true, plugin_owned?: true, plugin: "tesla"},
          executor: {FakeExecutor, :no_extra, []}
        })

      test_pid = self()

      tainted = %{
        agent_name: "main",
        source_trust: :operator,
        computer_use_origin: :interactive,
        conversation_key: {"telegram", "cap-#{System.unique_integer([:positive])}", :root},
        outside_sources: MapSet.new([{:tool, "web_fetch"}]),
        reply_fn: fn part -> send(test_pid, {:reply, part}) end,
        approval_fn: fn _request -> {:ok, "TOKEN", :new} end
      }

      assert {:ok, %{success: false, error: error}} =
               Capability.execute(cap, %{"vin" => "V"}, tainted)

      assert error =~ "Not sent"
      assert_received {:reply, {:approval_prompt, _prompt, "TOKEN"}}
    end
  end
end
