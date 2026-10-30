defmodule FermixCore.Cues.FollowUpReadiness do
  @moduledoc """
  Whether a watcher's follow-up can run now (M60_WATCHER_CODING_RUNS.md §3.2):
  the one check `manage_watcher` runs when a follow-up is set up and
  `Cues.FollowUps.held/2` runs at every trigger. Every tool the follow-up names
  must be one this computer offers, and a family with its own readiness says
  what is missing in its own words, with where to fix it:

    * **Coding agents** (`codex_run`, `claude_code_run`, `codex_cloud_run`):
      the harness on and allowed (`[fermix_core.harness] enabled`, `approved`),
      the vendor's program on `PATH`, and signed in: Codex by its sign-in file
      (a refresh token), while Claude Code's `:unverified` (its config dir,
      with the credentials in the Mac keychain, which Fermix never reads)
      counts as signed in. Codex cloud also needs `cloud_enabled`.
    * **Plugins**: a tool no capability carries is looked up in the plugins'
      manifests, and the plugin that declares it is named with its state
      (`Plugins.Status`).
    * **Channels**: the channel the follow-up reports to is turned on and set
      up (`Readiness.channel_enabled?/1`, `Readiness.channel_configured?/1`).

  A tool no capability carries and no plugin declares is named as not set up.

  Cheap reads only, since the scheduler asks at every trigger: the
  application's config, `PATH` lookups, the Codex sign-in file, the plugin
  manifests and the auth file. Never a subprocess, the network or the
  keychain, so a plugin whose host runtime is a program on this computer is
  named not ready without its runtime's rung, whose check runs that program.

  Seams (opts): `:capability_registry`, `:harness_config` (the
  `[fermix_core.harness]` keyword), `:vendor_opts` (`Harness.Vendors`'
  `:find_executable`, `:codex_home` and `:claude_config_dir`), `:plugins` (a
  0-arity function answering `{:ok, [Plugin.t()]}`), `:plugin_status` (a
  1-arity function of a plugin answering its status) and `:channel_ready?` (a
  1-arity function of a channel's config key).
  """

  require Logger

  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Harness.Config, as: HarnessConfig
  alias FermixCore.Harness.Vendors
  alias FermixCore.Plugins.Registry, as: PluginRegistry
  alias FermixCore.Plugins.Status, as: PluginStatus
  alias FermixCore.Readiness

  @seams [:harness_config, :vendor_opts, :plugins, :plugin_status, :channel_ready?]

  # Each coding run tool, its vendor and its rail.
  @coding_tools %{
    "codex_run" => {"codex", :local},
    "claude_code_run" => {"claude", :local},
    "codex_cloud_run" => {"codex", :cloud}
  }
  @vendor_tools %{"codex" => "codex_run", "claude" => "claude_code_run"}
  @vendor_names %{"codex" => "Codex", "claude" => "Claude Code"}

  # The report platforms whose channel has a switch and credentials to set up;
  # the phone and the Mac app are reached through a paired device instead.
  @channel_keys %{
    "telegram" => :telegram,
    "slack" => :slack,
    "discord" => :discord,
    "whatsapp" => :whatsapp
  }
  @channel_names %{
    telegram: "Telegram",
    slack: "Slack",
    discord: "Discord",
    whatsapp: "WhatsApp"
  }

  @agents_off "Coding agents are turned off: turn them on in the coding agents settings."
  @agents_not_allowed "Coding agents are not allowed on this computer yet: allow them in " <>
                        "the coding agents settings."
  @cloud_off "Codex cloud is off: set `[fermix_core.harness] cloud_enabled = true` in the " <>
               "settings file, then restart Fermix."

  @doc "The opts this check reads beyond `:capability_registry`, for a caller to pass on."
  @spec seams() :: [atom()]
  def seams, do: @seams

  @doc """
  Whether follow-up `job` (its `allowed_tools` and delivery) can run now:
  `:ready`, or Fermix's sentence naming what is missing and where to fix it.
  """
  @spec check(map(), keyword()) :: :ready | {:not_ready, String.t()}
  def check(%{allowed_tools: tools} = job, opts) when is_list(tools) and is_list(opts) do
    {gaps, unregistered} = Enum.reduce(tools, {[], []}, &tool_gap(&1, &2, opts))

    sentences =
      Enum.reverse(gaps) ++
        plugin_gaps(Enum.reverse(unregistered), opts) ++ delivery_gap(job, opts)

    case Enum.uniq(sentences) do
      [] -> :ready
      sentences -> {:not_ready, Enum.join(sentences, " ")}
    end
  end

  @doc """
  The coding run tool a follow-up uses when the owner names no coding agent
  (§3.2): the configured default (`[fermix_core.harness] default_vendor`), else
  the one that is ready, else Fermix's sentence asking which.
  """
  @spec coding_agent(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def coding_agent(opts) when is_list(opts) do
    case HarnessConfig.default_vendor(harness_config(opts)) do
      vendor when is_binary(vendor) -> {:ok, Map.fetch!(@vendor_tools, vendor)}
      nil -> the_one_ready(opts)
    end
  end

  defp the_one_ready(opts) do
    gaps = Map.new(@vendor_tools, fn {vendor, tool} -> {vendor, coding_gap(tool, opts)} end)

    case for({vendor, nil} <- gaps, do: vendor) do
      [vendor] ->
        {:ok, Map.fetch!(@vendor_tools, vendor)}

      [] ->
        {:error,
         "No coding agent is ready on this computer, so say which one the follow-up uses, " <>
           "Codex or Claude Code. " <> (gaps |> Map.values() |> Enum.uniq() |> Enum.join(" "))}

      _both ->
        {:error,
         "Codex and Claude Code are both ready and neither is the default, so say which one " <>
           "the follow-up uses."}
    end
  end

  # --- tools ------------------------------------------------------------------------

  defp tool_gap(tool, {gaps, unregistered}, opts) do
    cond do
      Map.has_key?(@coding_tools, tool) -> {add(gaps, coding_gap(tool, opts)), unregistered}
      registered?(tool, opts) -> {gaps, unregistered}
      true -> {gaps, [tool | unregistered]}
    end
  end

  defp add(gaps, nil), do: gaps
  defp add(gaps, sentence), do: [sentence | gaps]

  # The harness, the program, the sign-in, then whether the tool was loaded:
  # a program installed after Fermix started is loaded at its next start.
  defp coding_gap(tool, opts) do
    {vendor, rail} = Map.fetch!(@coding_tools, tool)
    config = harness_config(opts)
    vendor_opts = Keyword.get(opts, :vendor_opts, [])

    cond do
      not HarnessConfig.enabled?(config) -> @agents_off
      not HarnessConfig.approved?(config) -> @agents_not_allowed
      rail == :cloud and not HarnessConfig.cloud_enabled?(config) -> @cloud_off
      not Vendors.available?(vendor, vendor_opts) -> not_installed(vendor)
      Vendors.auth_state(vendor, vendor_opts) == :absent -> signed_out(vendor)
      not registered?(tool, opts) -> restart(vendor)
      true -> nil
    end
  end

  defp not_installed(vendor) do
    "#{vendor_name(vendor)} is not installed on this computer: install its `#{vendor}` " <>
      "program, then restart Fermix."
  end

  defp signed_out("codex"),
    do: "Codex is not signed in on this computer: run `codex login` there."

  defp signed_out("claude"),
    do: "Claude Code is not signed in on this computer: run `claude` there once and sign in."

  defp restart(vendor),
    do: "#{vendor_name(vendor)} was installed after Fermix started: restart Fermix to use it."

  defp vendor_name(vendor), do: Map.fetch!(@vendor_names, vendor)

  defp registered?(tool, opts) do
    registry = Keyword.get(opts, :capability_registry, CapabilityRegistry)
    match?({:ok, _capability}, CapabilityRegistry.find(registry, tool))
  end

  # --- plugins ----------------------------------------------------------------------

  defp plugin_gaps([], _opts), do: []

  defp plugin_gaps(tools, opts) do
    plugins = plugins(opts)

    {owned, unknown} =
      tools
      |> Enum.map(&{&1, Enum.find(plugins, fn plugin -> declares?(plugin, &1) end)})
      |> Enum.split_with(fn {_tool, plugin} -> plugin end)

    Enum.map(owned, fn {tool, plugin} -> plugin_gap(plugin, tool, opts) end) ++
      not_set_up(Enum.map(unknown, &elem(&1, 0)))
  end

  # The plugins are read only to name one; unreadable, the tool is named alone.
  defp plugins(opts) do
    case Keyword.get(opts, :plugins, &PluginRegistry.list/0).() do
      {:ok, plugins} when is_list(plugins) ->
        plugins

      {:error, reason} ->
        Logger.warning("Follow-up readiness could not read the plugins: #{inspect(reason)}")
        []
    end
  end

  defp declares?(plugin, tool), do: Enum.any?(plugin.tools, &(Map.get(&1, "name") == tool))

  defp plugin_gap(plugin, tool, opts) do
    title = plugin.display_name || plugin.name

    if runtime_program?(plugin),
      do: "#{title} is not ready, so #{tool} is not offered: check it under Plugins in settings.",
      else: plugin_words(plugin_status(plugin, opts), title, tool)
  end

  defp runtime_program?(%{runtime: %{"kind" => "remote_mcp"}}), do: false
  defp runtime_program?(%{runtime: runtime}), do: is_map(runtime)

  defp plugin_status(plugin, opts),
    do: Keyword.get(opts, :plugin_status, &PluginStatus.status/1).(plugin)

  defp plugin_words(:not_configured, title, _tool),
    do: "#{title} is turned off: turn it on under Plugins in settings."

  defp plugin_words(status, title, _tool)
       when status in [
              :needs_auth,
              :reauthorization_required,
              :wrong_region,
              :needs_client_config
            ],
       do: "#{title} is not connected: connect it under Plugins in settings."

  defp plugin_words(:needs_secret, title, _tool),
    do: "#{title} is waiting for its token: add it under Plugins in settings."

  defp plugin_words(status, title, _tool)
       when status in [:needs_config, :needs_workspace, :invalid_remote_config],
       do: "#{title} is waiting for a setting: finish it under Plugins in settings."

  defp plugin_words(status, title, _tool) when status in [:not_installed, :incompatible],
    do: "#{title} is not installed on this build of Fermix: install it under Plugins in settings."

  defp plugin_words(:ready, title, tool),
    do: "#{title} does not offer #{tool} now: check its settings under Plugins in settings."

  defp plugin_words(_status, title, tool),
    do: "#{title} is not ready, so #{tool} is not offered: check it under Plugins in settings."

  defp not_set_up([]), do: []

  defp not_set_up([tool]),
    do: [
      "#{tool} is not set up on this computer (its program was not found or its plugin is " <>
        "not installed)."
    ]

  defp not_set_up(tools),
    do: [
      "#{Enum.join(tools, ", ")} are not set up on this computer (a program was not found " <>
        "or a plugin is not installed)."
    ]

  # --- channels ---------------------------------------------------------------------

  defp delivery_gap(%{delivery_target: target}, opts) when is_map(target) do
    platform = Map.get(target, "platform") || Map.get(target, :platform)

    with {:ok, key} <- Map.fetch(@channel_keys, to_string(platform)),
         false <- channel_ready?(key, opts) do
      [
        "#{Map.fetch!(@channel_names, key)}, where the follow-up reports, is not set up: " <>
          "set it up under Channels in settings."
      ]
    else
      _ready_or_no_channel -> []
    end
  end

  defp delivery_gap(_job, _opts), do: []

  defp channel_ready?(key, opts) do
    ready? =
      Keyword.get(opts, :channel_ready?, fn channel ->
        Readiness.channel_enabled?(channel) and Readiness.channel_configured?(channel)
      end)

    ready?.(key)
  end

  defp harness_config(opts),
    do:
      Keyword.get_lazy(opts, :harness_config, fn ->
        Application.get_env(:fermix_core, :harness, [])
      end)
end
