defmodule FermixCore.Capabilities.Advertisement do
  @moduledoc """
  Prepares the context-sensitive capability surface shown to a provider.

  Dispatchability is owned by the caller. This module only applies optional
  executor hooks to the provider-visible copies: `advertise?/1` filters first,
  then `dynamic_parameters/1` refreshes the surviving schemas.

  Both hooks are looked up through `gate_exported?/2`, which **loads the module
  first**. BEAM code loading is lazy, so on a running daemon a tool module that
  no turn has touched yet exports nothing as far as `function_exported?/3` is
  concerned — and a gate that reads it directly skips itself exactly when it
  matters (2026-09-10: `recall_activity` was advertised on a turn whose Gate then
  refused it, because `RecallActivity` had never been loaded).
  """

  alias FermixCore.Capabilities.Capability

  @spec prepare([Capability.t()], map()) :: [Capability.t()]
  def prepare(capabilities, context) when is_list(capabilities) and is_map(context) do
    capabilities
    |> Enum.filter(&advertised?(&1, context))
    |> Enum.map(&refresh_schema(&1, context))
  end

  defp advertised?(%Capability{executor: {mod, _fun, _args}}, context) when is_atom(mod) do
    not gate_exported?(mod, :advertise?) or mod.advertise?(context)
  end

  defp advertised?(%Capability{}, _context), do: true

  defp refresh_schema(%Capability{executor: {mod, _fun, _args}} = capability, context)
       when is_atom(mod) do
    if gate_exported?(mod, :dynamic_parameters),
      do: %{capability | parameters: mod.dynamic_parameters(context)},
      else: capability
  end

  defp refresh_schema(%Capability{} = capability, _context), do: capability

  # An unloadable module (a stale registration) exports nothing and is left
  # ungated here — dispatch fails loudly at execute rather than silently here.
  defp gate_exported?(mod, hook),
    do: Code.ensure_loaded?(mod) and function_exported?(mod, hook, 1)
end
