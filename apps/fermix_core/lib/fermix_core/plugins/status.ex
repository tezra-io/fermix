defmodule FermixCore.Plugins.Status do
  @moduledoc """
  Local readiness checks for configured plugins.

  The ladder (M8 §8, checked in order): `:not_configured` (not enabled) →
  install/runtime states for `mcp`-rail plugins (`:missing_host_runtime`,
  `:needs_config`) → the remote-plugin ladder (§7.8, below) → the auth ladder
  (`:ready` for `auth: none`, else `:needs_client_config` / `:needs_auth` /
  `:reauthorization_required`).

  An enabled *name* with no loadable manifest is statusable too (the input
  shape for manifest-less names): `:not_installed` when the store has no
  entry, `:incompatible` when the store entry exists but no longer fits this
  core's support window (such entries are excluded from `Registry.list/1`,
  so they can never surface as a `%Plugin{}`).

  Only `:ready` registers capabilities (`Plugins.Capabilities`) and
  materializes an MCP server spec (`Dist.McpSource`).

  ## Remote plugins: startable, not callable (M27 §7.8)

  A `runtime.kind: remote_mcp` plugin answers the *startable* question here —
  credential present, access profile declared, one workspace selected — by
  asking `Dist.McpSource.remote_spec/1`, the same predicate that materializes
  the server spec. Deriving it twice is how the two drift, so the refusal
  reason is mapped straight onto the status: `:needs_secret`, then
  `:needs_workspace`, then `:invalid_remote_config`. A remote plugin holding a
  credential but no selected workspace is `:needs_workspace` and therefore
  registers **zero** agent tools.

  The *callable* question — the live client initialized and the whole signed
  contract matched — is `Capabilities.MCP.RuntimeStatus`'s, and it is layered
  on top of this ladder by daemon-side readers (setup UI, the daemon's
  `plugins_runtime_status` operation). It is deliberately not merged in here:
  this function must answer identically in a tree-less one-shot CLI VM, where
  that table does not exist and its absence must never be read as `:ready`.
  """

  alias FermixCore.Auth.Store
  alias FermixCore.Plugins.Config
  alias FermixCore.Plugins.Dist.McpSource
  alias FermixCore.Plugins.Dist.RuntimeProbe
  alias FermixCore.Plugins.Dist.Store, as: DistStore
  alias FermixCore.Plugins.Plugin
  alias FermixCore.Plugins.Registry
  alias FermixCore.Setup.ConfigStore

  @sentinel FermixCore.Setup.SecretWriter.sentinel()

  @spec status(Plugin.t() | String.t()) :: atom()
  def status(plugin_or_name), do: status(plugin_or_name, [])

  @doc """
  Status with explicit seams: `:probe` (keyword passed to
  `RuntimeProbe.probe/3` — tests must stub it) and `:installed_root` (the
  plugin store root for manifest-less names).
  """
  @spec status(Plugin.t() | String.t(), keyword()) :: atom()
  def status(%Plugin{} = plugin, opts) when is_list(opts) do
    cond do
      plugin.name not in Config.enabled_plugins() ->
        :not_configured

      missing_host_runtime?(plugin, opts) ->
        :missing_host_runtime

      missing_required_config?(plugin) ->
        :needs_config

      McpSource.remote?(plugin) ->
        remote_status(plugin)

      plugin.auth.type == :none ->
        :ready

      plugin.auth.type == :api_key ->
        api_key_status(plugin)

      missing_client_config?(plugin) ->
        :needs_client_config

      true ->
        auth_status(plugin)
    end
  end

  def status(name, opts) when is_binary(name) and is_list(opts) do
    case Registry.find(name) do
      {:ok, plugin} -> status(plugin, opts)
      :error -> absent_status(name, opts)
      {:error, _reason} -> :error
    end
  end

  @spec ready?(Plugin.t()) :: boolean()
  def ready?(%Plugin{} = plugin), do: status(plugin) == :ready

  @spec account_label(Plugin.t()) :: String.t() | nil
  def account_label(%Plugin{} = plugin) do
    with {:ok, entry} <- Store.read(Config.auth_profile(plugin)),
         account when is_map(account) <- Map.get(entry, :account),
         email when is_binary(email) <- Map.get(account, :email) do
      email
    else
      _other -> nil
    end
  end

  @spec granted_scopes(Plugin.t()) :: [String.t()]
  def granted_scopes(%Plugin{} = plugin) do
    case Store.read(Config.auth_profile(plugin)) do
      {:ok, entry} -> Map.get(entry, :granted_scopes, [])
      {:error, _reason} -> []
    end
  end

  # An enabled name with no `%Plugin{}` behind it: installed-but-incompatible
  # entries are visible only through the store (the registry excludes them);
  # anything else enabled-but-absent is simply not installed.
  defp absent_status(name, opts) do
    cond do
      name not in Config.enabled_plugins() -> :not_configured
      store_incompatible?(name, opts) -> :incompatible
      true -> :not_installed
    end
  end

  defp store_incompatible?(name, opts) do
    root = Keyword.get(opts, :installed_root) || ConfigStore.workspace_paths().plugins

    root
    |> DistStore.list()
    |> Enum.any?(&(&1.name == name and &1.status == :incompatible))
  end

  defp missing_host_runtime?(%Plugin{runtime: runtime} = plugin, opts) when is_map(runtime) do
    probe_opts = Keyword.get(opts, :probe, [])
    RuntimeProbe.probe(runtime, Path.dirname(plugin.path), probe_opts) != :ok
  end

  defp missing_host_runtime?(_plugin, _opts), do: false

  defp missing_required_config?(%Plugin{name: name, config: entries}) when is_list(entries) do
    configured = Config.plugin_settings(name)
    Enum.any?(entries, fn entry -> entry.required and not Map.has_key?(configured, entry.key) end)
  end

  defp missing_client_config?(%Plugin{auth: %{provider: provider, type: :oauth2}})
       when is_binary(provider) do
    config = Config.oauth_provider(provider)
    blank?(Keyword.get(config, :client_id)) or blank?(Keyword.get(config, :client_secret))
  end

  defp missing_client_config?(_plugin), do: false

  # api_key plugins are ready once their static credential is keychained;
  # otherwise they need it set (`fermix plugins auth set <name>`).
  defp api_key_status(%Plugin{name: name}) do
    case Config.plugin_secret(name) do
      @sentinel -> :needs_secret
      secret when is_binary(secret) and secret != "" -> :ready
      _missing -> :needs_secret
    end
  end

  # The startable predicate, asked of the one module that owns it. Its `with`
  # already runs in ladder order (runtime shape → credential → profile →
  # workspace), so mapping the refusal keeps the precedence in one place rather
  # than restating it here and letting the two versions drift.
  defp remote_status(%Plugin{} = plugin) do
    case McpSource.remote_spec(plugin) do
      {:ok, _spec} -> :ready
      {:error, {:needs_secret, _name}} -> :needs_secret
      {:error, {:needs_workspace, _name}} -> :needs_workspace
      {:error, {:invalid_remote_config, _detail}} -> :invalid_remote_config
      {:error, _unclassified} -> :invalid_remote_config
    end
  end

  defp auth_status(plugin) do
    case Store.read(Config.auth_profile(plugin)) do
      {:ok, %{status: "reauthorization_required"}} ->
        :reauthorization_required

      {:ok, %{status: "invalidated"}} ->
        :reauthorization_required

      {:ok, _entry} ->
        :ready

      {:error, {:provider_missing, _profile}} ->
        :needs_auth

      {:error, :no_auth_file} ->
        :needs_auth

      {:error, _reason} ->
        :error
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
