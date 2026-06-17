defmodule FermixCore.Plugins.PromptCatalog do
  @moduledoc """
  Per-plugin runtime index, derived from the profile's already-filtered
  capability snapshot so it can never advertise a tool the worker cannot call.

  Tool names come from the plugin-owned capabilities in the profile snapshot, so
  the index is by construction a subset of the callable tools (it inherits the
  profile's trust/allowed-tools/excluded-category/registry filtering). Skill
  names are the plugin's manifest skills that are actually loaded in the skill
  registry, so the index never points at a skill `skill_view` cannot open. The
  agent opens a listed skill with `skill_view` and calls the listed tools.

  Enabled plugins that are **not** ready still appear — as a status entry with
  no tools and a one-line remediation (M8 §8.2's crash/readiness visibility):
  the operator connected the plugin, so the model must be able to say *why*
  it is absent ("gmail needs auth — run `fermix plugins auth login gmail`")
  instead of the plugin silently vanishing from the catalog.
  """

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Plugins.Config
  alias FermixCore.Plugins.Plugin
  alias FermixCore.Plugins.Registry
  alias FermixCore.Plugins.Status

  @type entry :: %{
          name: String.t(),
          status: atom(),
          tools: [String.t()],
          skills: [String.t()],
          remediation: String.t() | nil
        }

  @doc """
  Build the index from a profile's filtered `capabilities` and the names of the
  currently loaded skills. Grouping the plugin-owned capabilities guarantees the
  listed tools match what the worker can call; skills are intersected with the
  loaded set. The registry is consulted only to map a plugin to its declared
  skill names and to compute the status of enabled plugins with no registered
  capabilities.
  """
  @spec entries([Capability.t()], [String.t()]) :: [entry()]
  def entries(capabilities, loaded_skill_names)
      when is_list(capabilities) and is_list(loaded_skill_names) do
    loaded = MapSet.new(loaded_skill_names)

    ready =
      capabilities
      |> Enum.filter(&plugin_owned?/1)
      |> Enum.group_by(&plugin_name/1)
      |> Enum.reject(fn {plugin, _caps} -> is_nil(plugin) end)
      |> Enum.map(fn {plugin, caps} -> entry(plugin, caps, loaded) end)

    covered = MapSet.new(ready, & &1.name)

    (ready ++ status_entries(covered))
    |> Enum.sort_by(& &1.name)
  end

  defp entry(plugin_name, caps, loaded) do
    %{
      name: plugin_name,
      status: :ready,
      tools: caps |> Enum.map(& &1.name) |> Enum.sort(),
      skills: plugin_name |> manifest_skill_names() |> Enum.filter(&MapSet.member?(loaded, &1)),
      remediation: nil
    }
  end

  # Enabled plugins with no capability-derived entry: anything not :ready
  # gets a status line. A :ready plugin without registered capabilities in
  # this profile stays invisible — profile filtering is intentional.
  defp status_entries(covered) do
    Config.enabled_plugins()
    |> Enum.reject(&MapSet.member?(covered, &1))
    |> Enum.map(&status_entry/1)
    |> Enum.reject(&(&1.status == :ready))
  end

  defp status_entry(name) do
    status = Status.status(name)

    %{
      name: name,
      status: status,
      tools: [],
      skills: [],
      remediation: remediation(status, name)
    }
  end

  defp remediation(:ready, _name), do: nil

  defp remediation(status, name) when status in [:needs_auth, :reauthorization_required],
    do: "connect it: run `fermix plugins auth login #{name}`"

  defp remediation(:needs_client_config, name),
    do: "its OAuth client is not configured — set it up on the setup page (plugin #{name})"

  defp remediation(:needs_config, name),
    do: "required config is missing — set it under [fermix_core.plugins.#{name}] in config.toml"

  defp remediation(:missing_host_runtime, name),
    do:
      "its host runtime is missing or too old — install it, then run `fermix plugins doctor #{name}`"

  defp remediation(:not_installed, name),
    do: "run `fermix plugins install #{name}`"

  defp remediation(:incompatible, name),
    do:
      "incompatible with this Fermix version — run `fermix plugins upgrade #{name}` or upgrade Fermix"

  defp remediation(_status, name), do: "run `fermix plugins doctor #{name}`"

  defp plugin_owned?(%Capability{metadata: metadata}),
    do: Map.get(metadata, :plugin_owned?) == true

  defp plugin_owned?(_capability), do: false

  defp plugin_name(%Capability{metadata: metadata}), do: Map.get(metadata, :plugin)

  defp manifest_skill_names(plugin_name) do
    case Registry.find(plugin_name) do
      {:ok, %Plugin{skills: skills}} ->
        skills |> Enum.map(&Map.get(&1, "name")) |> Enum.filter(&is_binary/1)

      _other ->
        []
    end
  end
end
