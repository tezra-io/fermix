defmodule FermixCore.Introspection.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry
  alias FermixCore.Introspection.Capabilities

  setup do
    registry = :"capability_introspection_#{System.unique_integer([:positive, :monotonic])}"

    {:ok, _pid} =
      start_supervised({Registry, [name: registry]}, id: {:capability_registry, registry})

    %{registry: registry}
  end

  test "summarizes capabilities by kind and exposes display-safe rows", %{registry: registry} do
    :ok = Registry.register(registry, capability("file_read", :builtin, :read_only))
    :ok = Registry.register(registry, capability("coding", :skill, :exec))
    :ok = Registry.register(registry, capability("github.search", :mcp, :external_api))

    assert {:ok, snapshot} = Capabilities.snapshot(registry: registry)

    assert snapshot.counts == %{builtin: 1, skill: 1, mcp: 1, total: 3}

    assert [
             %{
               name: "coding",
               kind: :skill,
               policy_class: :exec,
               hidden_from_agent?: false
             },
             %{name: "file_read", kind: :builtin},
             %{name: "github.search", kind: :mcp}
           ] = snapshot.capabilities
  end

  test "filters capabilities by kind", %{registry: registry} do
    :ok = Registry.register(registry, capability("file_read", :builtin, :read_only))
    :ok = Registry.register(registry, capability("coding", :skill, :exec))

    assert {:ok, snapshot} = Capabilities.snapshot(registry: registry, kind: :skill)

    assert snapshot.counts == %{builtin: 0, skill: 1, mcp: 0, total: 1}
    assert [%{name: "coding", kind: :skill}] = snapshot.capabilities
  end

  test "returns an error when the capability registry is unavailable" do
    assert {:error, {:capability_registry_unavailable, reason}} =
             Capabilities.snapshot(registry: :missing_capability_registry)

    assert reason != nil
  end

  test "exposes only allowlisted metadata keys", %{registry: registry} do
    :ok =
      Registry.register(
        registry,
        capability("coding", :skill, :exec, %{
          skill: "coding",
          trust: :trusted,
          source_path: "/Users/sujshe/.fermix/skills/coding/SKILL.md",
          api_key: "secret"
        })
      )

    assert {:ok, %{capabilities: [row]}} = Capabilities.snapshot(registry: registry)
    assert row.metadata == %{skill: "coding", trust: :trusted}
  end

  defp capability(name, kind, policy_class, metadata \\ %{source: "test"}) do
    Capability.new(%{
      name: name,
      description: "#{name} description",
      parameters: %{"type" => "object"},
      kind: kind,
      policy_class: policy_class,
      executor: {__MODULE__, :execute, []},
      metadata: metadata
    })
  end

  def execute(_args, _context), do: {:ok, "unused"}
end
