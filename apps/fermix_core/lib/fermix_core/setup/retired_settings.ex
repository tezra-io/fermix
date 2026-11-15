defmodule FermixCore.Setup.RetiredSettings do
  @moduledoc """
  The settings a build retired that a settings file may still carry, and the
  sentence that names each.

  A retired setting is never a refusal: a `config.toml` or `machine.toml` an
  earlier engine wrote keeps booting. The settings load accepts it and drops
  it, so nothing acts on it, and the next settings save writes the file
  without it, because the writers render only what the load kept
  (`FermixCore.Setup.ConfigStore`).

  The load names none of them. It runs on every poll of the setup state, on
  the model routing's reads and on the doctor's, so a notice said there
  repeated about once a second for as long as the app was open, and forever on
  a server nobody saves settings on. `notices/3` finds them as data in the
  decoded files instead, and each engine process says them once, where its
  logging is in place (`ConfigStore.say_retired_settings/0`).
  """

  alias FermixCore.Capabilities.MCP.Config, as: McpConfig
  alias FermixCore.ComputerHistory.Config, as: ComputerHistoryConfig
  alias FermixCore.Plugins.Retired
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Tools.Media.Registry, as: MediaRegistry

  # The image backends this build retired, as `[fermix_core.tools.generate_image]
  # backend` spells them once trimmed and lowercased. The live set is the media
  # registry's, never a second list kept here.
  @image_backends ~w(openai_codex)

  # The `[fermix_core.plugins]` keys that are not a plugin's section.
  @plugins_keys ~w(enabled entries dev_local)

  @doc """
  Whether `backend` (trimmed and lowercased) is an image backend this build
  retired: the settings load accepts it and drops it, leaving the image tool
  with no backend.
  """
  @spec image_backend?(String.t()) :: boolean()
  def image_backend?(backend) when is_binary(backend), do: backend in @image_backends

  @doc """
  The sentence for each retired setting the settings still carry, each once,
  in a fixed order, `[]` for none. `document` is `config.toml` decoded and
  joined with this computer's own settings (`MachineFile.join/2`, what the
  load normalizes), `machine` is `machine.toml` decoded, and `contents` is
  `config.toml` as written, whose `[mcp.*]` blocks have their own reader. A
  value of a shape the load would refuse names nothing here.
  """
  @spec notices(map(), map(), String.t()) :: [String.t()]
  def notices(document, machine, contents)
      when is_map(document) and is_map(machine) and is_binary(contents) do
    [
      always_on(document),
      provider_keys(document),
      computer_history(document, machine),
      image_backend(document),
      plugins(document),
      plugin_secrets(document),
      mobile_fcm(document),
      mcp_inbound(contents)
    ]
    |> List.flatten()
    |> Enum.uniq()
  end

  # Always On's test switch, from before every build served Always On.
  defp always_on(document) do
    if value(document, ["fermix_core", "always_on"]) == nil,
      do: [],
      else: [
        "config.toml [fermix_core.always_on] is retired: every build of Fermix serves Always " <>
          "On, so the table is ignored, and the next settings save writes the file without it."
      ]
  end

  # The keys a provider's descriptor retired (`Descriptor.retired_config_keys`).
  defp provider_keys(document) do
    for descriptor <- Descriptor.all(),
        %{} = block <- [value(document, ["fermix_core", "providers", "#{descriptor.id}"])],
        present <- [Enum.filter(descriptor.retired_config_keys, &Map.has_key?(block, "#{&1}"))],
        present != [] do
      "config.toml [fermix_core.providers.#{descriptor.id}] key(s) " <>
        "#{Enum.map_join(present, ", ", &Atom.to_string/1)} are retired: this build no " <>
        "longer reads them, so they are ignored, and the next settings save writes the " <>
        "file without them."
    end
  end

  # The history keys retired (`ComputerHistory.Config.retired_keys/0`), in the
  # home's table and in this computer's own.
  defp computer_history(document, machine) do
    tables = [
      value(document, ["fermix_core", "computer_history"]),
      value(machine, ["fermix_core", "computer_history"])
    ]

    for %{} = table <- tables,
        key <- ComputerHistoryConfig.retired_keys(),
        Map.has_key?(table, "#{key}"),
        do: computer_history_notice(key)
  end

  defp computer_history_notice(:sites) do
    "computer_history.sites is retired: every site in an allowlisted browser is " <>
      "recorded; remove the key from the file that holds it"
  end

  defp image_backend(document) do
    with backend when is_binary(backend) <-
           value(document, ["fermix_core", "tools", "generate_image", "backend"]),
         name = backend |> String.trim() |> String.downcase(),
         true <- image_backend?(name) do
      [
        "config.toml [fermix_core.tools.generate_image] backend #{inspect(name)} is retired: " <>
          "this build no longer has it, so image generation stays off until you choose " <>
          "#{Enum.join(Enum.sort(MediaRegistry.providers(:image)), ", ")} in setup, and the " <>
          "next settings save writes the file without it."
      ]
    else
      _live_or_absent -> []
    end
  end

  # A plugin this build retired, named in `enabled` or by its own section
  # (`Plugins.Retired`).
  defp plugins(document) do
    case value(document, ["fermix_core", "plugins"]) do
      %{} = config ->
        config |> plugin_names() |> Enum.filter(&Retired.retired?/1) |> plugins_notice()

      _absent ->
        []
    end
  end

  # The names the load reads: `enabled` only where it is a list, as the load
  # takes it.
  defp plugin_names(config) do
    listed = if is_list(config["enabled"]), do: config["enabled"], else: []
    enabled = for name <- listed, is_binary(name), do: String.trim(name)
    entries = if is_map(config["entries"]), do: Map.keys(config["entries"]), else: []
    Enum.uniq(enabled ++ entries ++ Map.keys(Map.drop(config, @plugins_keys)))
  end

  defp plugins_notice([]), do: []

  defp plugins_notice(names) do
    [
      "retired plugin(s) #{inspect(Enum.sort(names))} dropped from [fermix_core.plugins]: " <>
        "this build no longer offers them, so they are not started and the next config save " <>
        "writes the file without them. Any credential you stored for them is left exactly as " <>
        "it is — revoke it at the source if you have not already."
    ]
  end

  # The mapping goes with the plugin; the secret it points at does not.
  defp plugin_secrets(document) do
    with %{} = secrets <- value(document, ["fermix_core", "plugin_secrets"]),
         [_ | _] = names <- Enum.filter(Map.keys(secrets), &Retired.retired?/1) do
      [
        "retired plugin(s) #{inspect(Enum.sort(names))} dropped from " <>
          "[fermix_core.plugin_secrets]: the stored value itself is untouched."
      ]
    else
      _none -> []
    end
  end

  # Android push straight through FCM, retired before any release shipped it.
  defp mobile_fcm(document) do
    if value(document, ["fermix_channels", "mobile", "fcm"]) == nil,
      do: [],
      else: [
        "config.toml [fermix_channels.mobile.fcm] is retired: Android phones are pushed " <>
          "through Fermix's push relay with no settings, so the table is ignored, and the next " <>
          "settings save writes the file without it."
      ]
  end

  # The inbound MCP server, retired before it was ever started (M73).
  defp mcp_inbound(contents) do
    if McpConfig.retired_sections(contents) == [],
      do: [],
      else: [
        "config.toml [mcp.inbound] is retired: this build has no inbound MCP server, so the " <>
          "section is ignored, and the next settings save writes the file without it."
      ]
  end

  # The value at `path` in a decoded document, a table or not; nil where any
  # step of it is absent or is no table.
  defp value(document, path) do
    Enum.reduce_while(path, document, fn key, table ->
      case table do
        %{^key => inner} -> {:cont, inner}
        _absent -> {:halt, nil}
      end
    end)
  end
end
