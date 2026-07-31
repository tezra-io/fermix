defmodule FermixCore.Capabilities.Advertisement do
  @moduledoc """
  Prepares the context-sensitive capability surface shown to a provider.

  Dispatchability is owned by the caller. This module only applies optional
  executor hooks to the provider-visible copies: `advertise?/1` filters first,
  then `dynamic_parameters/1` refreshes the surviving schemas.
  """

  alias FermixCore.Capabilities.Capability

  @spec prepare([Capability.t()], map()) :: [Capability.t()]
  def prepare(capabilities, context) when is_list(capabilities) and is_map(context) do
    capabilities
    |> Enum.filter(&advertised?(&1, context))
    |> Enum.map(&refresh_schema(&1, context))
  end

  defp advertised?(%Capability{executor: {mod, _fun, _args}}, context) when is_atom(mod) do
    not function_exported?(mod, :advertise?, 1) or mod.advertise?(context)
  end

  defp advertised?(%Capability{}, _context), do: true

  defp refresh_schema(%Capability{executor: {mod, _fun, _args}} = capability, context)
       when is_atom(mod) do
    if function_exported?(mod, :dynamic_parameters, 1),
      do: %{capability | parameters: mod.dynamic_parameters(context)},
      else: capability
  end

  defp refresh_schema(%Capability{} = capability, _context), do: capability
end
