defmodule FermixCore.Plugins.Config do
  @moduledoc """
  Persists plugin enablement and provider client configuration.
  """

  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.Plugins.Plugin
  alias FermixCore.Plugins.Registry
  alias FermixCore.Plugins.Runtime
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixCore.Setup.SecretPaths
  alias FermixCore.Setup.SecretStore
  alias FermixCore.Setup.SecretWriter

  require Logger

  @type snapshot_result :: {:ok, ConfigStore.runtime_config()} | {:error, term()}

  @spec enable(String.t()) :: snapshot_result()
  def enable(name) when is_binary(name) do
    with {:ok, plugin} <- fetch_plugin(name) do
      ConfigStore.current_snapshot()
      |> update_plugins(fn plugins -> enable_plugin(plugins, plugin) end)
      |> commit()
    end
  end

  @spec disable(String.t()) :: snapshot_result()
  def disable(name) when is_binary(name) do
    with {:ok, plugin} <- fetch_plugin(name) do
      auth_profile = auth_profile(plugin)

      ConfigStore.current_snapshot()
      |> update_plugins(fn plugins -> disable_plugin(plugins, plugin) end)
      |> commit()
      |> stop_refresh_if_unused(auth_profile)
    end
  end

  @spec set_oauth_provider(String.t(), keyword()) :: snapshot_result()
  def set_oauth_provider(provider, opts) when is_binary(provider) and is_list(opts) do
    with {:ok, provider_config} <- normalize_oauth_provider(provider, opts) do
      ConfigStore.current_snapshot()
      |> update_oauth(provider, provider_config)
      |> commit()
    end
  end

  @doc """
  Persist one manifest-declared config value (M8.1 §4.4) under
  `[fermix_core.plugins.<name>]`. The key must be declared in the plugin's
  manifest `config` block; the commit reloads the runtime so an `mcp` child
  restarts with the new env.
  """
  @spec set_plugin_setting(String.t(), String.t(), String.t()) :: snapshot_result()
  def set_plugin_setting(name, key, value)
      when is_binary(name) and is_binary(key) and is_binary(value) do
    with {:ok, plugin} <- fetch_plugin(name),
         :ok <- validate_plugin_setting(plugin, key, value) do
      ConfigStore.current_snapshot()
      |> update_plugins(fn plugins -> put_plugin_setting(plugins, plugin, key, value) end)
      |> commit()
    end
  end

  # The operator's Connect selection for a plugin that declares a
  # `resource_scope` (M27 §7.5). Lowercase plumbing keys, exactly like
  # `auth_profile` and `enabled` — deliberately NOT UPPER_SNAKE, because
  # `plugin_settings/1` is the mcp env-injection seam and these must never
  # reach a child process environment.
  @selection_keys ~w(access_profile workspace_id workspace_label)
  @max_workspace_id_bytes 256
  @max_workspace_label_bytes 128

  @doc """
  Persist the operator's Connect selection: the access profile and the one
  selected workspace's opaque ID plus its display-only label (M27 §7.5).

  Written the way `enable/1` writes `auth_profile`, not through
  `set_plugin_setting/3` — see `@selection_keys`.

  It persists and applies but does **not** reload the runtime. A selection
  change requires a *proven* source-qualified stop and reconnect, which
  `Plugins.RemoteSetup.select_workspace/2` owns; `Runtime.reload/1`'s
  best-effort fan-out proves nothing and would race that reconnect. Nothing is
  lost by skipping it: the reconnect's own `:ready` transition is what
  invalidates the agent's cached tool list (`MCP.Server`), and it fires after
  discovery rather than before it.
  """
  @spec set_workspace_selection(String.t(), keyword()) :: snapshot_result()
  def set_workspace_selection(name, opts) when is_binary(name) and is_list(opts) do
    with {:ok, plugin} <- fetch_plugin(name),
         {:ok, profile} <- validate_access_profile(plugin, Keyword.get(opts, :access_profile)),
         {:ok, id} <- validate_workspace_id(Keyword.get(opts, :workspace_id)),
         {:ok, label} <- validate_workspace_label(Keyword.get(opts, :workspace_label)) do
      selection = [access_profile: profile, workspace_id: id, workspace_label: label]

      ConfigStore.current_snapshot()
      |> update_plugins(fn plugins -> put_selection(plugins, plugin, selection) end)
      |> persist()
    end
  end

  @doc """
  The access profile to persist: a name the manifest declares, or — when the
  operator supplied none — the manifest's signed `default: true` profile.

  Any other value is invalid configuration and is refused. A profile name is an
  enforcement boundary (§8.1), so a typo must never quietly resolve to the safe
  default and leave the operator believing they selected the other one.
  """
  @spec validate_access_profile(Plugin.t(), term()) :: {:ok, String.t()} | {:error, term()}
  def validate_access_profile(%Plugin{} = plugin, nil), do: signed_default_profile(plugin)

  def validate_access_profile(%Plugin{tool_profiles: profiles, name: name}, profile)
      when is_binary(profile) do
    if Enum.any?(profiles, &(Map.get(&1, "name") == profile)),
      do: {:ok, profile},
      else: {:error, {:invalid_access_profile, name, profile}}
  end

  def validate_access_profile(%Plugin{name: name}, _profile),
    do: {:error, {:invalid_access_profile, name, :not_a_string}}

  @doc """
  Validate a selected workspace ID: opaque, 1–#{@max_workspace_id_bytes} bytes,
  visible ASCII, no whitespace or control characters (§7.5).

  The value never appears in the error — it names the operator's own data, and
  a rejection reason is read by logs and UIs that must not carry it.
  """
  @spec validate_workspace_id(term()) :: {:ok, String.t()} | {:error, term()}
  def validate_workspace_id(id) when is_binary(id) do
    if byte_size(id) in 1..@max_workspace_id_bytes and visible_ascii?(id),
      do: {:ok, id},
      else: {:error, {:invalid_workspace_id, byte_size(id)}}
  end

  def validate_workspace_id(_id), do: {:error, {:invalid_workspace_id, :not_a_string}}

  @doc """
  Validate a workspace label: display-only, valid UTF-8, control-free, trimmed,
  at most #{@max_workspace_label_bytes} bytes (§7.5).

  It is never sent in place of the ID and never trusted for authorization, so
  the empty string is a legal label — an unnamed workspace is a display
  problem, not a configuration error.
  """
  @spec validate_workspace_label(term()) :: {:ok, String.t()} | {:error, term()}
  def validate_workspace_label(label) when is_binary(label) do
    cond do
      not String.valid?(label) -> {:error, {:invalid_workspace_label, :not_utf8}}
      byte_size(String.trim(label)) > @max_workspace_label_bytes -> label_too_long(label)
      control_characters?(String.trim(label)) -> {:error, {:invalid_workspace_label, :control}}
      true -> {:ok, String.trim(label)}
    end
  end

  def validate_workspace_label(_label), do: {:error, {:invalid_workspace_label, :not_a_string}}

  defp label_too_long(label),
    do: {:error, {:invalid_workspace_label, byte_size(String.trim(label))}}

  defp signed_default_profile(%Plugin{tool_profiles: profiles, name: name}) do
    case Enum.find(profiles, &(Map.get(&1, "default") == true)) do
      %{"name" => profile} when is_binary(profile) -> {:ok, profile}
      _none -> {:error, {:no_default_access_profile, name}}
    end
  end

  defp visible_ascii?(value) do
    value |> :binary.bin_to_list() |> Enum.all?(&(&1 >= 0x21 and &1 <= 0x7E))
  end

  # C0, DEL, and C1 — a label reaches an operator-facing surface, and the C1
  # block is exactly what a naive `[[:cntrl:]]` check misses.
  defp control_characters?(value) do
    value
    |> String.to_charlist()
    |> Enum.any?(&(&1 < 0x20 or &1 == 0x7F or (&1 >= 0x80 and &1 <= 0x9F)))
  end

  @doc """
  Persist the static credential an `auth: api_key` plugin authenticates with
  (M16). The plaintext lands at the plugin's registered `SecretPaths` path;
  `commit/1` routes it through the secure-on-save path, so it is keychained
  (not written to `config.toml` plaintext) and the runtime reflects it.
  """
  @spec set_plugin_secret(String.t(), String.t()) :: snapshot_result()
  def set_plugin_secret(name, value) when is_binary(name) and is_binary(value) do
    with {:ok, plugin} <- fetch_plugin(name),
         :ok <- ensure_api_key(plugin),
         {:ok, secret} <- fetch_plugin_secret(name),
         :ok <- ensure_non_blank(value) do
      ConfigStore.current_snapshot()
      |> SecretStore.put_snapshot_value(secret.path, value)
      |> commit()
    end
  end

  @doc """
  Forget a plugin's api_key: delete the OS-keychain item, then drop the config
  reference to it. The plugin resolves `:needs_secret` afterwards.

  The order is the point (M27 §7.5). The config sentinel is the only pointer to
  the stored credential, so dropping it first and then failing the delete would
  leave a live secret on the machine that nothing can name or remove. A failed
  deletion returns `{:error, reason}` with the reference intact for an explicit
  retry; it never reports success. Forgetting is local: it does not revoke the
  credential with the provider.
  """
  @spec forget_plugin_secret(String.t()) :: snapshot_result()
  def forget_plugin_secret(name) when is_binary(name) do
    snapshot = ConfigStore.current_snapshot()

    with {:ok, _plugin} <- fetch_plugin(name),
         {:ok, secret} <- fetch_plugin_secret(name),
         :ok <- delete_keychain_item(secret, snapshot) do
      snapshot
      |> SecretStore.delete_snapshot_value(secret.path)
      |> commit()
    end
  end

  # The snapshot's own profile names the keychain namespace its secrets live
  # in, exactly as the secure-on-save path derives it — reading app env here
  # would delete from the wrong namespace on a profile switch.
  defp delete_keychain_item(secret, snapshot) do
    profile = SecretStore.get_snapshot_value(snapshot, [:fermix_core, :profile])

    case SecretWriter.delete(secret.key, profile: profile) do
      :ok -> :ok
      {:error, reason} -> {:error, {:keychain_delete_failed, secret.env, reason}}
    end
  end

  @doc """
  The resolved static credential for an `api_key` plugin (read from app env,
  populated at boot from the keychain), or `nil` when unset.
  """
  @spec plugin_secret(String.t()) :: String.t() | nil
  def plugin_secret(name) when is_binary(name) do
    case Application.get_env(:fermix_core, :plugin_secrets, %{}) do
      secrets when is_map(secrets) -> Map.get(secrets, name)
      secrets when is_list(secrets) -> plugin_secret_from_keyword(secrets, name)
      _other -> nil
    end
  end

  @doc """
  The operator's persisted workspace selection for one plugin (M27 §7.5), read
  back in the shape `set_workspace_selection/2` writes.

  Every field is `nil` on a plugin that binds no workspace or has not chosen
  one yet, so a reader gets one record rather than three probes for keys. It is
  the read half of `@selection_keys`, which is why it lives beside the writer.
  """
  @spec workspace_selection(String.t()) :: %{
          access_profile: String.t() | nil,
          workspace_id: String.t() | nil,
          workspace_label: String.t() | nil
        }
  def workspace_selection(name) when is_binary(name) do
    entry =
      Application.get_env(:fermix_core, :plugins, [])
      |> Keyword.get(:entries, %{})
      |> Map.get(name, [])

    %{
      access_profile: selection_value(entry, :access_profile),
      workspace_id: selection_value(entry, :workspace_id),
      workspace_label: selection_value(entry, :workspace_label)
    }
  end

  # A TOML reload brings these back as atoms and a fresh write uses atoms too,
  # but a hand-edited file can spell them as strings; read by name for the same
  # reason `put_selection/3` replaces by name.
  defp selection_value(entry, key) do
    Enum.find_value(entry, fn {entry_key, value} ->
      if to_string(entry_key) == Atom.to_string(key) and is_binary(value), do: value
    end)
  end

  @spec auth_profile(Plugin.t()) :: String.t()
  def auth_profile(%Plugin{} = plugin) do
    plugin
    |> plugin_entry()
    |> Keyword.get(:auth_profile, default_auth_profile(plugin))
  end

  @spec enabled_plugins() :: [String.t()]
  def enabled_plugins do
    Application.get_env(:fermix_core, :plugins, [])
    |> Keyword.get(:enabled, [])
    |> Enum.filter(&is_binary/1)
  end

  @upper_snake_regex ~r/^[A-Z][A-Z0-9_]*$/

  @doc """
  The UPPER_SNAKE config values persisted under `[fermix_core.plugins.<name>]`
  (e.g. `OBSIDIAN_VAULT_PATH`). This is the env-injection seam for `mcp`-rail
  plugins: `Dist.McpSource` merges these into the child process environment,
  and `Status` checks the manifest's required keys against them. Lowercase
  entry keys (`auth_profile`, `enabled`) are plumbing, never env.
  """
  @spec plugin_settings(String.t()) :: %{String.t() => String.t()}
  def plugin_settings(name) when is_binary(name) do
    Application.get_env(:fermix_core, :plugins, [])
    |> Keyword.get(:entries, %{})
    |> Map.get(name, [])
    |> Enum.reduce(%{}, &collect_setting/2)
  end

  defp collect_setting({key, value}, acc) do
    key = to_string(key)
    value = to_string(value)

    if Regex.match?(@upper_snake_regex, key) and String.trim(value) != "",
      do: Map.put(acc, key, value),
      else: acc
  end

  defp collect_setting(_other, acc), do: acc

  @spec oauth_provider(String.t()) :: keyword()
  def oauth_provider(provider) when is_binary(provider) do
    case Application.get_env(:fermix_core, :oauth, %{}) do
      oauth when is_map(oauth) -> Map.get(oauth, provider, [])
      oauth when is_list(oauth) -> oauth_provider_from_keyword(oauth, provider)
      _other -> []
    end
  end

  @spec default_auth_profile(Plugin.t()) :: String.t()
  def default_auth_profile(%Plugin{name: name, auth: auth}) do
    profile_key = Map.get(auth, :profile_key) || name
    "#{profile_key}:primary"
  end

  defp fetch_plugin(name) do
    case Registry.find(name) do
      {:ok, plugin} -> {:ok, plugin}
      :error -> {:error, {:unknown_plugin, name}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_api_key(%Plugin{auth: %{type: :api_key}}), do: :ok
  defp ensure_api_key(%Plugin{name: name}), do: {:error, {:not_api_key_plugin, name}}

  defp fetch_plugin_secret(name) do
    case SecretPaths.fetch_plugin(name) do
      nil -> {:error, {:plugin_secret_unsupported, name}}
      secret -> {:ok, secret}
    end
  end

  defp ensure_non_blank(value) do
    if String.trim(value) == "", do: {:error, :blank_secret}, else: :ok
  end

  defp plugin_secret_from_keyword(secrets, name) do
    Enum.find_value(secrets, fn {key, value} -> if to_string(key) == name, do: value end)
  end

  defp update_plugins(snapshot, fun) when is_function(fun, 1) do
    fermix_core = Map.get(snapshot, :fermix_core, [])
    plugins = fermix_core |> Keyword.get(:plugins, []) |> fun.()
    Map.put(snapshot, :fermix_core, Keyword.put(fermix_core, :plugins, plugins))
  end

  # Read-modify-write, like disable_plugin: drop the `enabled: false` marker,
  # claim only the keys enable owns (auth_profile), preserve everything else —
  # saved settings (e.g. OBSIDIAN_VAULT_PATH) survive disable → enable.
  defp enable_plugin(plugins, plugin) do
    entry =
      plugin
      |> plugin_entry(plugins)
      |> Keyword.delete(:enabled)
      |> Keyword.put_new(:auth_profile, default_auth_profile(plugin))

    enabled = plugins |> Keyword.get(:enabled, []) |> add_enabled(plugin.name)
    entries = plugins |> Keyword.get(:entries, %{}) |> Map.put(plugin.name, entry)

    plugins
    |> Keyword.put(:enabled, enabled)
    |> Keyword.put(:entries, entries)
  end

  defp disable_plugin(plugins, plugin) do
    entry =
      plugin
      |> plugin_entry(plugins)
      |> Keyword.put(:enabled, false)
      |> Keyword.put_new(:auth_profile, default_auth_profile(plugin))

    enabled =
      plugins
      |> Keyword.get(:enabled, [])
      |> Enum.reject(&(&1 == plugin.name))

    entries = plugins |> Keyword.get(:entries, %{}) |> Map.put(plugin.name, entry)

    plugins
    |> Keyword.put(:enabled, enabled)
    |> Keyword.put(:entries, entries)
  end

  # The declared-key check subsumes the UPPER_SNAKE shape: manifest config
  # keys already passed the registry's key regex at decode.
  defp validate_plugin_setting(%Plugin{config: entries}, key, value) do
    cond do
      not Enum.any?(entries, &(&1.key == key)) -> {:error, {:unknown_config_key, key}}
      String.trim(value) == "" -> {:error, {:blank_config_value, key}}
      true -> :ok
    end
  end

  # TOML-loaded entries carry UPPER_SNAKE keys as strings (lowercase plumbing
  # keys normalize to atoms); replace by string identity so an overwrite never
  # leaves a stale duplicate behind.
  defp put_plugin_setting(plugins, plugin, key, value) do
    entry =
      plugin
      |> plugin_entry(plugins)
      |> Enum.reject(fn {entry_key, _value} -> to_string(entry_key) == key end)
      |> Kernel.++([{key, value}])

    entries = plugins |> Keyword.get(:entries, %{}) |> Map.put(plugin.name, entry)
    Keyword.put(plugins, :entries, entries)
  end

  # Same string-identity replacement `put_plugin_setting/4` uses: a TOML reload
  # brings these back as atoms while a fresh write uses atoms too, so replacing
  # by name keeps one entry per key instead of a stale duplicate.
  defp put_selection(plugins, plugin, selection) do
    entry =
      plugin
      |> plugin_entry(plugins)
      |> Enum.reject(fn {key, _value} -> to_string(key) in @selection_keys end)
      |> Kernel.++(selection)

    entries = plugins |> Keyword.get(:entries, %{}) |> Map.put(plugin.name, entry)
    Keyword.put(plugins, :entries, entries)
  end

  defp add_enabled(enabled, name) do
    enabled
    |> Enum.filter(&is_binary/1)
    |> then(fn names -> if name in names, do: names, else: names ++ [name] end)
  end

  defp plugin_entry(%Plugin{} = plugin) do
    plugin_entry(plugin, Application.get_env(:fermix_core, :plugins, []))
  end

  defp plugin_entry(%Plugin{name: name}, plugins) when is_list(plugins) do
    plugins |> Keyword.get(:entries, %{}) |> Map.get(name, [])
  end

  defp oauth_provider_from_keyword(oauth, provider) do
    Enum.find_value(oauth, [], fn {key, value} ->
      if to_string(key) == provider, do: value
    end)
  end

  defp update_oauth(snapshot, provider, provider_config) do
    fermix_core = Map.get(snapshot, :fermix_core, [])
    oauth = fermix_core |> Keyword.get(:oauth, %{}) |> normalize_oauth_map()
    updated = Map.put(oauth, provider, provider_config)
    Map.put(snapshot, :fermix_core, Keyword.put(fermix_core, :oauth, updated))
  end

  # Providers whose OAuth client config gets strict field validation. Slack is
  # listed even though the Slack *plugin* authenticates with an api_key bot token
  # (reads): its OAuth provider is deferred scaffolding for the user-token
  # search.messages flow (M16 §7.1, see Auth.OAuthProviders.build/2). Keeping it
  # here means a Slack OAuth client is validated like every other provider rather
  # than falling through to the permissive clause below.
  @registry_oauth_providers ~w(google github notion x slack)

  defp normalize_oauth_provider(provider, opts) when provider in @registry_oauth_providers do
    client_type = Keyword.get(opts, :client_type, "desktop_public_pkce")

    cond do
      client_type != "desktop_public_pkce" ->
        {:error, {:invalid_oauth_client_type, provider, client_type}}

      blank?(Keyword.get(opts, :client_id)) ->
        {:error, {:missing_oauth_client_field, provider, :client_id}}

      blank?(Keyword.get(opts, :client_secret)) ->
        {:error, {:missing_oauth_client_field, provider, :client_secret}}

      true ->
        {:ok, normalized_oauth_provider(opts, client_type)}
    end
  end

  defp normalize_oauth_provider(_provider, opts) do
    {:ok, normalized_oauth_provider(opts, Keyword.get(opts, :client_type))}
  end

  # The redirect port is persisted only when the operator chose one — the
  # per-provider defaults live in FermixCore.Auth.OAuthProviders.
  defp normalized_oauth_provider(opts, client_type) do
    [
      client_type: client_type,
      client_id: Keyword.get(opts, :client_id),
      client_secret: Keyword.get(opts, :client_secret),
      redirect_host: Keyword.get(opts, :redirect_host),
      redirect_port: Keyword.get(opts, :redirect_port)
    ]
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp normalize_oauth_map(oauth) when is_map(oauth), do: oauth

  defp normalize_oauth_map(oauth) when is_list(oauth) do
    Enum.into(oauth, %{}, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_oauth_map(_oauth), do: %{}

  defp commit(snapshot) do
    with {:ok, snapshot} <- persist(snapshot) do
      reload_runtime()
      {:ok, snapshot}
    end
  end

  # Save + apply only. The caller that owns a stronger reconciliation than the
  # generic fan-out (`set_workspace_selection/2`) uses this directly.
  defp persist(snapshot) do
    # The second write tail, and it consults the SAME predicate as the wizard's
    # — `RestartState.writable/0`, one owner: the `plugin:<name>` and
    # `oauth_client:<provider>` families reach `config.toml` through here and
    # never through the wizard, so a refusal in one tail alone would let a
    # plugin write revert an outside edit silently.
    with :ok <- RestartState.writable(),
         :ok <- ConfigStore.save_snapshot(snapshot),
         :ok <- ConfigStore.apply_snapshot(snapshot) do
      {:ok, ConfigStore.current_snapshot()}
    end
  end

  # The config change is already persisted; the live reload is best-effort, so a
  # reload failure does not fail the save. But it is surfaced loudly (not a quiet
  # warning) because a failed reload means the running agent will not reflect the
  # change until the daemon restarts — the operator needs to know.
  defp reload_runtime do
    case Runtime.reload() do
      {:ok, _summary} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Plugin runtime reload failed after config change: #{inspect(reason)}. " <>
            "The change is saved but the running agent will not reflect it until restart."
        )
    end

    :ok
  end

  defp stop_refresh_if_unused({:ok, snapshot}, auth_profile) do
    TokenSupervisor.stop_profile(auth_profile)
    {:ok, snapshot}
  end

  defp stop_refresh_if_unused({:error, _reason} = err, _auth_profile), do: err
end
