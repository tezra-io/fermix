defmodule FermixCore.Capabilities.AdvertisementTest do
  @moduledoc """
  The per-turn advertisement surface. The load-bearing case is the one the
  2026-09-10 incident found: a tool module the running daemon has not loaded yet
  (BEAM code loading is lazy) skipped its own `advertise?/1` gate and was offered
  anyway, because `function_exported?/3` answers false for an unloaded module.
  The gate must LOAD the module before it decides — for `advertise?/1` and for
  `dynamic_parameters/1` alike.
  """
  # async: false — unloads a module from the global code table.
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.Advertisement
  alias FermixCore.Capabilities.Capability
  alias FermixTestSupport.LazyTool
  alias FermixTestSupport.LazyTool.Unloader

  # A tool whose description is refreshed per turn, like its schema: what it can
  # do is only known once the daemon is running (computer use reads it from the
  # installed helper, M86 F1), while its registered description was read at boot.
  defmodule DescribedTool do
    @spec dynamic_description(map()) :: String.t()
    def dynamic_description(context) when is_map(context),
      do: "Refreshed for #{Map.get(context, :reader, "nobody")}."

    @spec execute(map(), map()) :: {:ok, map()}
    def execute(_args, _context), do: {:ok, %{success: true, output: "unused"}}
  end

  setup do
    on_exit(&Unloader.reload!/0)
    :ok
  end

  defp capability(module) do
    Capability.new(%{
      name: "lazy_tool",
      description: "A gated tool double.",
      parameters: %{type: "object", properties: %{"registered" => %{type: "string"}}},
      kind: :builtin,
      executor: {module, :execute, []},
      policy_class: :network
    })
  end

  defp names(capabilities, context),
    do: capabilities |> Advertisement.prepare(context) |> Enum.map(& &1.name)

  test "an UNLOADED module's advertise?/1 still filters the tool" do
    :ok = Unloader.unload!()
    refute function_exported?(LazyTool, :advertise?, 1)

    assert names([capability(LazyTool)], %{}) == []
  end

  test "an unloaded module that permits the turn is advertised with its refreshed schema" do
    :ok = Unloader.unload!()

    assert [advertised] =
             Advertisement.prepare([capability(LazyTool)], %{lazy_tool_allowed?: true})

    assert advertised.name == "lazy_tool"
    assert advertised.parameters == LazyTool.dynamic_parameters(%{})
  end

  test "a loaded module is filtered by the same gate" do
    :ok = Unloader.reload!()

    assert names([capability(LazyTool)], %{}) == []
    assert names([capability(LazyTool)], %{lazy_tool_allowed?: true}) == ["lazy_tool"]
  end

  test "an executor module that declares no gate is always advertised" do
    # `Kernel` stands in for any module without the optional callbacks: the gate
    # is opt-in, so a tool that declares neither hook is untouched.
    assert names([capability(Kernel)], %{}) == ["lazy_tool"]
  end

  test "a module's dynamic_description/1 replaces the registered description for the turn" do
    assert [advertised] = Advertisement.prepare([capability(DescribedTool)], %{reader: "main"})

    assert advertised.description == "Refreshed for main."
    assert advertised.parameters == capability(DescribedTool).parameters
  end

  test "a module without dynamic_description/1 keeps the description it registered" do
    assert [advertised] = Advertisement.prepare([capability(Kernel)], %{})
    assert advertised.description == "A gated tool double."

    assert [lazy] = Advertisement.prepare([capability(LazyTool)], %{lazy_tool_allowed?: true})
    assert lazy.description == "A gated tool double."
  end
end
