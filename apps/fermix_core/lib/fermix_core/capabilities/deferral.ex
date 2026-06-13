defmodule FermixCore.Capabilities.Deferral do
  @moduledoc """
  Tool-schema deferral partition (M10 §3.2).

  Splits trust-filtered capabilities into the ADVERTISED set (full schemas on
  the provider wire) and the DEFERRED set (plugin and MCP tools — names stay
  visible in the prompt prose; schemas load on demand through the bridge
  tools). The dispatchable surface is always advertised ∪ deferred, derived
  from the same filtered list, so trust enforcement is identical for both.

  Deferral is gated by `[fermix_core.tools.tool_search] enabled` — a single
  boolean. Disabled means byte-identical to the inline design: everything is
  advertised, nothing is deferred, and the bridges are not seeded.
  """

  alias FermixCore.Capabilities.Capability

  @bridge_names ~w(tool_search tool_describe tool_call)

  @type partition :: %{advertised: [Capability.t()], deferred: [Capability.t()]}

  @doc "Names of the three bridge tools (never themselves deferred)."
  @spec bridge_names() :: [String.t()]
  def bridge_names, do: @bridge_names

  @doc """
  Whether tool-schema deferral is enabled. Reads
  `[fermix_core.tools.tool_search] enabled`; **absent means `true`** —
  deferral is default-on, so installs that upgrade without writing the block
  get it, while an explicit `enabled = false` is preserved (the kill switch).
  Any non-boolean value fails loud — config errors are boot errors, not
  silent fallbacks.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    :fermix_core
    |> Application.get_env(:tools, [])
    |> get_in([:tool_search, :enabled])
    |> validate_enabled!()
  end

  defp validate_enabled!(nil), do: true
  defp validate_enabled!(value) when is_boolean(value), do: value

  defp validate_enabled!(other) do
    raise ArgumentError,
          "[fermix_core.tools.tool_search] enabled must be true or false, " <>
            "got: #{inspect(other)}"
  end

  @doc """
  Whether a capability's schema defers: plugin-owned tools (category
  `:plugin`) and MCP server tools. Builtins — including the bridges — never
  defer; unknown shapes fail safe into the advertised set.
  """
  @spec deferred?(Capability.t()) :: boolean()
  def deferred?(%Capability{name: name}) when name in @bridge_names, do: false
  def deferred?(%Capability{kind: :mcp}), do: true

  def deferred?(%Capability{metadata: metadata}) when is_map(metadata),
    do: Map.get(metadata, :category) == :plugin

  def deferred?(%Capability{}), do: false

  @doc """
  Partition capabilities into advertised vs deferred. With deferral disabled
  everything is advertised (the off-semantics contract: byte-identical to
  the inline design).
  """
  @spec partition([Capability.t()]) :: partition()
  def partition(capabilities) when is_list(capabilities) do
    if enabled?() do
      {deferred, advertised} = Enum.split_with(capabilities, &deferred?/1)
      %{advertised: advertised, deferred: deferred}
    else
      %{advertised: capabilities, deferred: []}
    end
  end
end
