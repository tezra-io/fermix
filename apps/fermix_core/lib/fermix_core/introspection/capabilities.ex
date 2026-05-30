defmodule FermixCore.Introspection.Capabilities do
  @moduledoc """
  Read-only capability registry projection for CLI and dashboard surfaces.
  """

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry

  @type snapshot :: %{
          counts: %{
            builtin: non_neg_integer(),
            skill: non_neg_integer(),
            mcp: non_neg_integer(),
            total: non_neg_integer()
          },
          capabilities: [map()]
        }

  @safe_metadata_keys %{
    builtin: [:tool_module],
    skill: [:skill, :trust],
    mcp: [:mcp_server, :original_name, :sanitized_name, :approved?]
  }

  @spec snapshot(keyword()) :: {:ok, snapshot()} | {:error, term()}
  def snapshot(opts \\ []) when is_list(opts) do
    registry = Keyword.get(opts, :registry, Registry)
    kind = normalize_kind(Keyword.get(opts, :kind, :all))

    with {:ok, capabilities} <- list_capabilities(registry, kind) do
      rows = Enum.map(capabilities, &row/1)
      {:ok, %{counts: counts(rows), capabilities: rows}}
    end
  end

  defp list_capabilities(registry, kind) do
    {:ok, Registry.list(registry, kind: kind, include_hidden?: true)}
  rescue
    error in ArgumentError ->
      {:error, {:capability_registry_unavailable, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:capability_registry_unavailable, reason}}
  end

  defp normalize_kind(kind) when kind in [:builtin, :skill, :mcp, :all], do: kind
  defp normalize_kind("builtin"), do: :builtin
  defp normalize_kind("skill"), do: :skill
  defp normalize_kind("mcp"), do: :mcp
  defp normalize_kind("all"), do: :all

  defp normalize_kind(other),
    do: raise(ArgumentError, "invalid capability kind: #{inspect(other)}")

  defp row(%Capability{} = capability) do
    %{
      name: capability.name,
      description: capability.description,
      kind: capability.kind,
      policy_class: capability.policy_class,
      hidden_from_agent?: capability.hidden_from_agent?,
      metadata: safe_metadata(capability.kind, capability.metadata)
    }
  end

  defp safe_metadata(kind, metadata) when is_map(metadata) do
    @safe_metadata_keys
    |> Map.get(kind, [])
    |> Enum.reduce(%{}, &put_safe_metadata(&2, metadata, &1))
  end

  defp put_safe_metadata(acc, metadata, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(metadata, key) -> Map.put(acc, key, Map.fetch!(metadata, key))
      Map.has_key?(metadata, string_key) -> Map.put(acc, key, Map.fetch!(metadata, string_key))
      true -> acc
    end
  end

  defp counts(rows) do
    base = %{builtin: 0, skill: 0, mcp: 0, total: length(rows)}

    Enum.reduce(rows, base, fn %{kind: kind}, acc ->
      Map.update!(acc, kind, &(&1 + 1))
    end)
  end
end
