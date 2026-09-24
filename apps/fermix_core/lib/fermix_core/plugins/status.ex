defmodule FermixCore.Plugins.Status do
  @moduledoc """
  Local readiness checks for configured plugins.

  The ladder (M8 §8, checked in order): `:not_configured` (not enabled) →
  install/runtime states for `mcp`-rail plugins (`:missing_host_runtime`,
  `:needs_config`) → the remote-plugin ladder (§7.8, below) → the auth ladder
  (`:ready` for `auth: none`, else `:needs_client_config` / `:needs_auth` /
  `:reauthorization_required` / `:wrong_region`).

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

  alias FermixCore.Auth.OAuthProviders
  alias FermixCore.Auth.Store
  alias FermixCore.Plugins.Config
  alias FermixCore.Plugins.Dist.McpSource
  alias FermixCore.Plugins.Dist.RuntimeProbe
  alias FermixCore.Plugins.Dist.Store, as: DistStore
  alias FermixCore.Plugins.Plugin
  alias FermixCore.Plugins.Registry
  alias FermixCore.Setup.ConfigStore

  @sentinels FermixCore.Setup.SecretWriter.sentinels()

  # The one spelling a `requires_setting` gate accepts. A second accepted
  # spelling would be a second code path for one decision.
  @setting_on "true"

  # Every atom the ladder below answers with, in ladder order. It is a published
  # vocabulary: `FermixCore.Management.Plugins` carries one sentence per status
  # and the management contract test asserts the two sets agree, so a status
  # added to a clause here fails that test rather than reaching a surface with
  # no words for it.
  @statuses [
    :not_configured,
    :missing_host_runtime,
    :needs_config,
    :needs_secret,
    :needs_workspace,
    :invalid_remote_config,
    :needs_client_config,
    :needs_auth,
    :reauthorization_required,
    :wrong_region,
    :ready,
    :not_installed,
    :incompatible,
    :error
  ]

  @doc "Every status this ladder answers with, in ladder order."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

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

  @doc """
  Whether the plugin's stored grant is quarantined because its provider refused
  the saved sign-in client (`Auth.ClientRejection`).

  The ladder publishes such a grant as `:reauthorization_required`, the status
  vocabulary having no word of its own for it; this predicate is how the
  surfaces that word the cause tell it apart. It reads the auth store and
  nothing else, so it answers identically in a tree-less CLI VM. An unreadable
  store or registry is not a refused client: `status/1` reports those itself.
  """
  @spec client_rejected?(Plugin.t() | String.t()) :: boolean()
  def client_rejected?(%Plugin{} = plugin) do
    case Store.read(Config.auth_profile(plugin)) do
      {:ok, entry} -> Map.get(entry, :status) == "client_rejected"
      {:error, _reason} -> false
    end
  end

  def client_rejected?(name) when is_binary(name) do
    case Registry.find(name) do
      {:ok, plugin} -> client_rejected?(plugin)
      :error -> false
      {:error, _reason} -> false
    end
  end

  @spec granted_scopes(Plugin.t()) :: [String.t()]
  def granted_scopes(%Plugin{} = plugin) do
    case Store.read(Config.auth_profile(plugin)) do
      {:ok, entry} -> Map.get(entry, :granted_scopes, [])
      {:error, _reason} -> []
    end
  end

  @doc """
  The account region recorded on the plugin's stored grant, or `nil`.

  Read the same way `granted_scopes/1` reads its half of the grant, so it answers
  identically in a tree-less CLI VM. It is what selects a `request.regional_urls`
  host at call time (M40 §4.3): a provider whose accounts live in fixed regional
  hosts records the region at sign-in, and `nil` means the plugin has no host to
  call rather than a default one.
  """
  @spec region(Plugin.t()) :: String.t() | nil
  def region(%Plugin{} = plugin) do
    case Store.read(Config.auth_profile(plugin)) do
      {:ok, entry} -> Map.get(entry, :region)
      {:error, _reason} -> nil
    end
  end

  @doc """
  The account's own region, as a sign-in found it, when it is not the region the
  sign-in client chose; `nil` otherwise.

  Read the same way `region/1` reads its half of the grant, so it answers
  identically in a tree-less CLI VM. It is only ever recorded beside a
  `wrong_region` status, and it is what lets a row name the region the operator
  should have chosen instead of asking them to guess. `nil` beside that status
  means the provider refused without naming a region this registry knows.
  """
  @spec region_actual(Plugin.t()) :: String.t() | nil
  def region_actual(%Plugin{} = plugin) do
    case Store.read(Config.auth_profile(plugin)) do
      {:ok, entry} -> Map.get(entry, :region_actual)
      {:error, _reason} -> nil
    end
  end

  @doc """
  Whether one of a plugin's own `config` keys reads exactly `"true"`.

  The one resolver behind both `requires_setting` gates — the per-tool one
  (M40 §3.2) and the `runtime` one (M8 §9.3) — so a spelling can never mean
  "on" for one and "off" for the other. One spelling only: `"TRUE"`, `"1"` and
  `"yes"` are all off.
  """
  @spec setting_on?(Plugin.t(), String.t()) :: boolean()
  def setting_on?(%Plugin{name: name}, key) when is_binary(key) and key != "",
    do: Map.get(Config.plugin_settings(name), key) == @setting_on

  @doc """
  Whether a tool's `requires_setting` gate is satisfied (M40 §3.2).

  A tool with no `requires_setting` is always satisfied. Two surfaces consult
  this: `Plugins.Capabilities` to decide what to advertise, and
  `Plugins.ToolExecutor` to refuse a call that arrived anyway.
  """
  @spec tool_setting_satisfied?(Plugin.t(), map()) :: boolean()
  def tool_setting_satisfied?(%Plugin{} = plugin, tool) when is_map(tool) do
    case Map.get(tool, "requires_setting") do
      nil -> true
      key when is_binary(key) -> setting_on?(plugin, key)
    end
  end

  @doc """
  Whether a plugin's local runtime may be spawned (M8 §9.3).

  A manifest may gate its own child process on one of its `config` keys, so an
  operator switch decides whether a vendored helper runs at all rather than only
  which of its tools are advertised. A runtime with no gate — or no runtime
  block — is always satisfied.

  Deliberately NOT part of `status/2`: the gate says whether a process is
  wanted, not whether the plugin is installed, configured and signed in. Folding
  it into the ladder would make a row report `missing_host_runtime` or
  `needs_config` because the operator left an optional helper switched off, and
  every published status sentence would become untrue.
  """
  @spec runtime_setting_satisfied?(Plugin.t()) :: boolean()
  def runtime_setting_satisfied?(%Plugin{runtime: %{"requires_setting" => key}} = plugin)
      when is_binary(key),
      do: setting_on?(plugin, key)

  def runtime_setting_satisfied?(%Plugin{}), do: true

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

    blank?(Keyword.get(config, :client_id)) or blank?(Keyword.get(config, :client_secret)) or
      missing_client_region?(provider, config)
  end

  defp missing_client_config?(_plugin), do: false

  # A regional provider's client is incomplete without a region: the region is
  # the token-exchange audience, so a sign-in under a client that has none is
  # refused before the browser opens. A provider this registry does not define
  # offers no regions to choose, which is why membership is asked first rather
  # than letting `regions/1` raise inside the ladder.
  defp missing_client_region?(provider, config) do
    provider in OAuthProviders.providers() and OAuthProviders.regions(provider) != [] and
      blank?(Keyword.get(config, :region))
  end

  # api_key plugins are ready once their static credential is keychained;
  # otherwise they need it set (`fermix plugins auth set <name>`).
  defp api_key_status(%Plugin{name: name}) do
    case Config.plugin_secret(name) do
      sentinel when sentinel in @sentinels -> :needs_secret
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

      # The provider refused the saved sign-in client, so the grant cannot
      # renew. `client_rejected?/1` tells the cause apart for the surfaces.
      {:ok, %{status: "client_rejected"}} ->
        :reauthorization_required

      # The grant is real, and minted for a region the account is not in. Every
      # call to the chosen region's host is refused by the provider, so the
      # plugin is not ready and signing in again under the same client cannot
      # help: the region on the sign-in client is the fix.
      {:ok, %{status: "wrong_region"}} ->
        :wrong_region

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
