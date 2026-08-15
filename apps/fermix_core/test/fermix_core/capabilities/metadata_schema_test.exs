defmodule FermixCore.Capabilities.MetadataSchemaTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Capabilities.Registry
  alias FermixCore.Introspection.Wire

  @known_categories [
    :file,
    :web,
    :media,
    :git,
    :delegation,
    :skill_admin,
    :config,
    :memory,
    :scheduling,
    :channel,
    :system
  ]

  setup do
    name = :"metadata_schema_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: name})
    BuiltinSeeder.start_link(capability_registry: name)
    %{registry: name}
  end

  test "every registered built-in has complete JSON-safe M7 metadata", %{registry: registry} do
    builtins = Registry.list(registry, kind: :builtin)

    assert length(builtins) >= 23

    for capability <- builtins do
      metadata = capability.metadata

      assert is_binary(metadata.when_to_use), capability.name
      assert String.trim(metadata.when_to_use) != "", capability.name
      assert metadata.category in @known_categories, capability.name
      assert is_list(metadata.examples), capability.name
      assert Enum.all?(metadata.examples, &valid_example?/1), capability.name
      assert is_list(metadata.failure_modes), capability.name
      assert Enum.all?(metadata.failure_modes, &valid_failure_mode?/1), capability.name
      assert Map.has_key?(metadata, :requires_setup), capability.name
      assert valid_requires_setup?(metadata.requires_setup), capability.name

      assert is_map(Wire.json_safe(metadata))
    end
  end

  defp valid_example?(%{args: args, note: note}) when is_map(args) and is_binary(note), do: true
  defp valid_example?(_example), do: false

  # `nil` for a keyless built-in; a credential-gated one (MILESTONE_31 §14.1
  # `place_search`) states its requirement as exactly these three keys, each a
  # non-empty string the introspection wire can render. The key set is pinned so
  # a later tool cannot ship a differently-shaped requirement that `tool_help`
  # would render as a blank or missing instruction.
  @requires_setup_keys [:config_path, :credential, :description]

  defp valid_requires_setup?(nil), do: true

  defp valid_requires_setup?(requirement) when is_map(requirement) do
    requirement |> Map.keys() |> Enum.sort() == @requires_setup_keys and
      Enum.all?(requirement, fn {_key, value} ->
        is_binary(value) and String.trim(value) != ""
      end)
  end

  defp valid_requires_setup?(_requirement), do: false

  defp valid_failure_mode?(%{tag: tag, description: description})
       when is_binary(tag) and is_binary(description),
       do: true

  defp valid_failure_mode?(_mode), do: false
end
