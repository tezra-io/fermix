defmodule FermixCore.Capabilities.RegistryTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry

  defmodule FakeMod do
    def execute(_args, _ctx, _extra \\ nil), do: {:ok, :ok}
  end

  setup do
    name = :"capreg_#{System.unique_integer([:positive])}"
    pid = start_supervised!({Registry, name: name})
    %{registry: name, pid: pid}
  end

  defp cap(name, opts \\ []) do
    Capability.new(%{
      name: name,
      description: "test #{name}",
      parameters: %{type: "object"},
      kind: Keyword.get(opts, :kind, :builtin),
      executor: {FakeMod, :execute, []},
      policy_class: Keyword.get(opts, :policy_class, :read_only),
      hidden_from_agent?: Keyword.get(opts, :hidden_from_agent?, false),
      owner_only?: Keyword.get(opts, :owner_only?, false),
      metadata: Keyword.get(opts, :metadata, %{})
    })
  end

  # `:read_only` bounds what a guest may DO; it says nothing about whose data a
  # read returns. `owner_only?` is the second axis: capabilities that hand back
  # the owner's files, memories or scheduled-job records are never in a guest's
  # surface even though their policy class admits them.
  describe "list/2 with :owner_only? capabilities" do
    setup %{registry: reg} do
      :ok = Registry.register(reg, cap("file_read", owner_only?: true))
      :ok = Registry.register(reg, cap("list_jobs", owner_only?: true))
      :ok = Registry.register(reg, cap("react"))
      :ok
    end

    test "an explicit guest never sees them", %{registry: reg} do
      names = reg |> Registry.list(trust: :guest) |> Enum.map(& &1.name)

      assert names == ["react"]
    end

    test "an operator sees everything", %{registry: reg} do
      names = reg |> Registry.list(trust: :operator) |> Enum.map(& &1.name)

      assert names == ["file_read", "list_jobs", "react"]
    end

    # A worker/internal caller narrows by policy class and never names a trust;
    # `list/2` with no `:trust` stays the storage primitive (registry.ex docs).
    test "a caller that never asked for a trust gate is unaffected", %{registry: reg} do
      assert reg |> Registry.list([]) |> length() == 3
      assert reg |> Registry.list(policy_classes: [:read_only]) |> length() == 3
    end

    test "an explicit guest policy narrowing still drops them", %{registry: reg} do
      names =
        reg |> Registry.list(trust: :guest, policy: [:read_only]) |> Enum.map(& &1.name)

      assert names == ["react"]
    end
  end

  describe "register/2 + find/2" do
    test "registers and looks up by name", %{registry: reg} do
      :ok = Registry.register(reg, cap("shell"))
      assert {:ok, %Capability{name: "shell"}} = Registry.find(reg, "shell")
    end

    test "rejects duplicate names loudly", %{registry: reg} do
      :ok = Registry.register(reg, cap("shell"))

      assert {:error, {:duplicate_name, "shell"}} =
               Registry.register(reg, cap("shell"))
    end

    test "find returns :error for unknown name", %{registry: reg} do
      assert :error = Registry.find(reg, "nope")
    end
  end

  describe "list/2 with :allowed_tools" do
    test "nil = no filter, returns everything", %{registry: reg} do
      :ok = Registry.register(reg, cap("a"))
      :ok = Registry.register(reg, cap("b"))

      names = reg |> Registry.list() |> Enum.map(& &1.name)
      assert names == ["a", "b"]
    end

    test "[] = empty list (not inherit-all)", %{registry: reg} do
      :ok = Registry.register(reg, cap("a"))
      :ok = Registry.register(reg, cap("b"))

      assert Registry.list(reg, allowed_tools: []) == []
    end

    test "[names] = exact allowlist filter", %{registry: reg} do
      :ok = Registry.register(reg, cap("a"))
      :ok = Registry.register(reg, cap("b"))
      :ok = Registry.register(reg, cap("c"))

      names =
        reg
        |> Registry.list(allowed_tools: ["a", "c"])
        |> Enum.map(& &1.name)

      assert names == ["a", "c"]
    end
  end

  describe "list/2 with :policy" do
    test "filters by allow class", %{registry: reg} do
      :ok = Registry.register(reg, cap("ro", policy_class: :read_only))
      :ok = Registry.register(reg, cap("rw", policy_class: :read_write))
      :ok = Registry.register(reg, cap("ex", policy_class: :exec))

      names =
        reg
        |> Registry.list(policy: [allow: [:read_only]])
        |> Enum.map(& &1.name)

      assert names == ["ro"]
    end

    test "deny overrides allow", %{registry: reg} do
      :ok = Registry.register(reg, cap("ro", policy_class: :read_only))
      :ok = Registry.register(reg, cap("ex", policy_class: :exec))

      names =
        reg
        |> Registry.list(policy: [allow: [:read_only, :exec], deny: [:exec]])
        |> Enum.map(& &1.name)

      assert names == ["ro"]
    end

    test "policy + allowlist compose", %{registry: reg} do
      :ok = Registry.register(reg, cap("a", policy_class: :read_only))
      :ok = Registry.register(reg, cap("b", policy_class: :read_only))
      :ok = Registry.register(reg, cap("c", policy_class: :exec))

      names =
        reg
        |> Registry.list(policy: [allow: [:read_only]], allowed_tools: ["a", "c"])
        |> Enum.map(& &1.name)

      assert names == ["a"]
    end

    test "raises on unknown policy class", %{registry: reg} do
      :ok = Registry.register(reg, cap("a"))

      assert_raise ArgumentError, ~r/invalid policy class/, fn ->
        Registry.list(reg, policy: [allow: [:bogus]])
      end
    end
  end

  describe "list/2 with :trust default policies" do
    setup %{registry: reg} do
      :ok = Registry.register(reg, cap("ro", policy_class: :read_only))
      :ok = Registry.register(reg, cap("rw", policy_class: :read_write))
      :ok = Registry.register(reg, cap("ex", policy_class: :exec))
      :ok = Registry.register(reg, cap("net", policy_class: :network))
      :ok = Registry.register(reg, cap("api", policy_class: :external_api))
      :ok
    end

    test "trust: :guest defaults to read-only and denies the rest", %{registry: reg} do
      names = reg |> Registry.list(trust: :guest) |> Enum.map(& &1.name)
      assert names == ["ro"]
    end

    test "trust: :operator allows the full surface incl. external_api", %{registry: reg} do
      names = reg |> Registry.list(trust: :operator) |> Enum.map(& &1.name)
      assert names == ["api", "ex", "net", "ro", "rw"]
    end

    test "explicit policy overrides trust default", %{registry: reg} do
      names =
        reg
        |> Registry.list(trust: :guest, policy: [:read_only, :exec])
        |> Enum.map(& &1.name)

      assert names == ["ex", "ro"]
    end

    test "policy as bare class list is treated as allow", %{registry: reg} do
      names = reg |> Registry.list(policy: [:exec]) |> Enum.map(& &1.name)
      assert names == ["ex"]
    end

    test "no trust + no policy returns everything (storage primitive)", %{registry: reg} do
      names = reg |> Registry.list() |> Enum.map(& &1.name)
      assert names == ["api", "ex", "net", "ro", "rw"]
    end

    test "explicit trust: nil defaults to least privilege (read-only)", %{registry: reg} do
      names = reg |> Registry.list(trust: nil) |> Enum.map(& &1.name)
      assert names == ["ro"]
    end
  end

  describe "default_policy_classes/1" do
    test "operator gets the full class surface, including :gui_control" do
      assert Enum.sort(Registry.default_policy_classes(:operator)) ==
               Enum.sort([:read_only, :read_write, :exec, :network, :external_api, :gui_control])
    end

    test "guest and nil collapse to read-only (never :gui_control)" do
      assert Registry.default_policy_classes(:guest) == [:read_only]
      assert Registry.default_policy_classes(nil) == [:read_only]
    end

    test "operator minus :read_write and :gui_control is the subagent worker surface" do
      # Mirrors Tools.Subagents.worker_policy/1: a delegated worker can read, browse,
      # and run skills/shell but can neither mutate local state (:read_write) nor
      # drive the desktop (:gui_control — attended, operator-only, never delegated).
      classes = Registry.default_policy_classes(:operator) -- [:read_write, :gui_control]
      assert Enum.sort(classes) == Enum.sort([:read_only, :exec, :network, :external_api])
      refute :read_write in classes
      refute :gui_control in classes
    end
  end

  describe "list/2 with :kind" do
    test "filters by capability kind", %{registry: reg} do
      :ok = Registry.register(reg, cap("a", kind: :builtin))
      :ok = Registry.register(reg, cap("b", kind: :skill))
      :ok = Registry.register(reg, cap("c", kind: :mcp))

      assert ["a"] = reg |> Registry.list(kind: :builtin) |> Enum.map(& &1.name)
      assert ["b"] = reg |> Registry.list(kind: :skill) |> Enum.map(& &1.name)
      assert ["c"] = reg |> Registry.list(kind: :mcp) |> Enum.map(& &1.name)
    end
  end

  describe "list_for/2 with visibility filters" do
    test "removes capabilities whose metadata category is excluded", %{registry: reg} do
      :ok = Registry.register(reg, cap("read", metadata: %{category: :file}))
      :ok = Registry.register(reg, cap("reply", metadata: %{category: :channel}))
      :ok = Registry.register(reg, cap("search", metadata: %{category: :web}))

      names =
        reg
        |> Registry.list_for(excluded_categories: [:channel])
        |> Enum.map(& &1.name)

      assert names == ["read", "search"]
    end

    test "nil and empty category exclusions preserve existing behavior", %{registry: reg} do
      :ok = Registry.register(reg, cap("plain"))
      :ok = Registry.register(reg, cap("reply", metadata: %{category: :channel}))

      assert ["plain", "reply"] =
               reg
               |> Registry.list_for(excluded_categories: nil)
               |> Enum.map(& &1.name)

      assert ["plain", "reply"] =
               reg
               |> Registry.list_for(excluded_categories: [])
               |> Enum.map(& &1.name)
    end

    test "capabilities without a category survive category filtering", %{registry: reg} do
      :ok = Registry.register(reg, cap("plain"))
      :ok = Registry.register(reg, cap("reply", metadata: %{category: :channel}))

      names =
        reg
        |> Registry.list_for(excluded_categories: [:channel])
        |> Enum.map(& &1.name)

      assert names == ["plain"]
    end

    test "composes category exclusion with allowlist and policy filters", %{registry: reg} do
      :ok = Registry.register(reg, cap("allowed", metadata: %{category: :file}))

      :ok =
        Registry.register(
          reg,
          cap("channel", metadata: %{category: :channel}, policy_class: :read_only)
        )

      :ok =
        Registry.register(
          reg,
          cap("write", metadata: %{category: :file}, policy_class: :read_write)
        )

      names =
        reg
        |> Registry.list_for(
          allowed_tools: ["allowed", "channel", "write"],
          excluded_categories: [:channel],
          policy: [allow: [:read_only]]
        )
        |> Enum.map(& &1.name)

      assert names == ["allowed"]
    end

    test "composes excluded names and policy class filters", %{registry: reg} do
      :ok = Registry.register(reg, cap("read", policy_class: :read_only))
      :ok = Registry.register(reg, cap("write", policy_class: :read_write))
      :ok = Registry.register(reg, cap("exec", policy_class: :exec))

      names =
        reg
        |> Registry.list_for(policy_classes: [:read_only, :read_write], excluded_names: ["read"])
        |> Enum.map(& &1.name)

      assert names == ["write"]
    end
  end

  describe "list/2 with :include_hidden?" do
    test "default false hides capabilities with hidden_from_agent?: true", %{registry: reg} do
      :ok = Registry.register(reg, cap("ok"))
      :ok = Registry.register(reg, cap("gated", hidden_from_agent?: true))

      assert ["ok"] = reg |> Registry.list() |> Enum.map(& &1.name)
    end

    test "true returns approval-gated capabilities", %{registry: reg} do
      :ok = Registry.register(reg, cap("gated", hidden_from_agent?: true))

      assert ["gated"] =
               reg
               |> Registry.list(include_hidden?: true)
               |> Enum.map(& &1.name)
    end
  end

  describe "unregister/2 and unregister_kind/3" do
    test "unregister/2 drops a single capability", %{registry: reg} do
      :ok = Registry.register(reg, cap("a"))
      :ok = Registry.unregister(reg, "a")
      assert :error = Registry.find(reg, "a")
    end

    test "unregister/2 is idempotent for unknown names", %{registry: reg} do
      assert :ok = Registry.unregister(reg, "missing")
    end

    test "unregister_kind/3 drops by kind + metadata match", %{registry: reg} do
      :ok = Registry.register(reg, cap("a", kind: :mcp, metadata: %{server: "github"}))
      :ok = Registry.register(reg, cap("b", kind: :mcp, metadata: %{server: "filesystem"}))
      :ok = Registry.register(reg, cap("c", kind: :builtin))

      :ok = Registry.unregister_kind(reg, :mcp, metadata: %{server: "github"})

      assert :error = Registry.find(reg, "a")
      assert {:ok, _} = Registry.find(reg, "b")
      assert {:ok, _} = Registry.find(reg, "c")
    end

    test "unregister_kind/3 with no metadata drops every capability of kind", %{registry: reg} do
      :ok = Registry.register(reg, cap("a", kind: :mcp, metadata: %{server: "x"}))
      :ok = Registry.register(reg, cap("b", kind: :mcp, metadata: %{server: "y"}))
      :ok = Registry.register(reg, cap("c", kind: :builtin))

      :ok = Registry.unregister_kind(reg, :mcp)

      assert :error = Registry.find(reg, "a")
      assert :error = Registry.find(reg, "b")
      assert {:ok, _} = Registry.find(reg, "c")
    end
  end

  describe "refresh/2" do
    test "is a no-op stub at Stage 1", %{registry: reg} do
      assert :ok = Registry.refresh(reg, :builtin)
      assert :ok = Registry.refresh(reg, :all)
    end
  end
end
