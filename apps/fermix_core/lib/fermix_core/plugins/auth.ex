defmodule FermixCore.Plugins.Auth do
  @moduledoc """
  OAuth login, refresh, and disconnect operations for plugins.
  """

  alias FermixCore.Auth.ClientRejection
  alias FermixCore.Auth.OAuthFlow
  alias FermixCore.Auth.OAuthProvider
  alias FermixCore.Auth.OAuthProviders
  alias FermixCore.Auth.Redaction
  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.Plugins.Auth.Telemetry, as: AuthTelemetry
  alias FermixCore.Plugins.Config
  alias FermixCore.Plugins.Plugin
  alias FermixCore.Plugins.Registry
  alias FermixCore.Plugins.Runtime

  require Logger

  @spec login(String.t(), keyword()) :: {:ok, Store.entry()} | {:error, term()}
  def login(name, opts \\ []) when is_binary(name) and is_list(opts) do
    started_at = AuthTelemetry.start()

    with {:ok, plugin} <- fetch_oauth_plugin(name),
         {:ok, provider} <- oauth_provider(plugin, opts),
         {:ok, tokens} <- OAuthFlow.start_loopback(provider, flow_opts(opts)),
         entry <- minted_entry(plugin, provider, tokens, opts),
         :ok <- Store.write(Config.default_auth_profile(plugin), entry),
         {:ok, _snapshot} <- Config.enable(plugin.name) do
      reload_token_manager(plugin)
      report(:login, plugin.name, {:ok, login_tag(entry)}, started_at)
      {:ok, entry}
    else
      {:error, _reason} = err ->
        report(:login, name, err, started_at)
        err
    end
  end

  @spec reauthorize(String.t(), keyword()) :: {:ok, Store.entry()} | {:error, term()}
  def reauthorize(name, opts \\ []), do: login(name, opts)

  @spec refresh(String.t()) :: {:ok, String.t()} | {:error, term()}
  def refresh(name) when is_binary(name) do
    started_at = AuthTelemetry.start()

    with {:ok, plugin} <- fetch_plugin(name),
         {:ok, token} <- TokenManager.refresh(Config.auth_profile(plugin)) do
      report(:refresh, plugin.name, {:ok, :ready}, started_at)
      {:ok, token}
    else
      {:error, _reason} = err ->
        report(:refresh, name, err, started_at)
        err
    end
  end

  @spec logout(String.t()) :: :ok | {:error, term()}
  def logout(name) when is_binary(name) do
    started_at = AuthTelemetry.start()

    with {:ok, plugin} <- fetch_plugin(name),
         auth_profile <- Config.auth_profile(plugin),
         :ok <- Store.delete_provider(auth_profile) do
      TokenSupervisor.stop_profile(auth_profile)

      case reload_runtime() do
        :ok ->
          report(:logout, plugin.name, {:ok, :logged_out}, started_at)
          :ok

        {:error, _reason} = err ->
          report(:logout, plugin.name, err, started_at)
          err
      end
    else
      {:error, _reason} = err ->
        report(:logout, name, err, started_at)
        err
    end
  end

  @doc """
  Store the static credential for an `api_key` plugin (M16). The value is
  keychained via the secure-on-save path; the plugin then resolves `:ready`.
  """
  @spec set_secret(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def set_secret(name, value) when is_binary(name) and is_binary(value) do
    started_at = AuthTelemetry.start()

    case Config.set_plugin_secret(name, value) do
      {:ok, _snapshot} ->
        report(:set, name, {:ok, :ready}, started_at)
        {:ok, name}

      {:error, _reason} = err ->
        report(:set, name, err, started_at)
        err
    end
  end

  @doc """
  Forget an `api_key` plugin's stored credential: the OS-keychain item is
  deleted and only then is the config reference dropped. Local only — it does
  not revoke the credential with the provider.
  """
  @spec forget_secret(String.t()) :: :ok | {:error, term()}
  def forget_secret(name) when is_binary(name) do
    started_at = AuthTelemetry.start()

    case Config.forget_plugin_secret(name) do
      {:ok, _snapshot} ->
        report(:clear, name, {:ok, :logged_out}, started_at)
        :ok

      {:error, _reason} = err ->
        report(:clear, name, err, started_at)
        err
    end
  end

  defp fetch_oauth_plugin(name) do
    case fetch_plugin(name) do
      {:ok, %Plugin{auth: %{type: :oauth2}} = plugin} -> {:ok, plugin}
      {:ok, %Plugin{}} -> {:error, {:auth_not_required, name}}
      {:error, _reason} = err -> err
    end
  end

  # The registry answers a name no plugin carries with a bare `:error`; every op
  # here turns it into the one typed failure it reports and returns.
  defp fetch_plugin(name) do
    case Registry.find(name) do
      {:ok, %Plugin{} = plugin} -> {:ok, plugin}
      :error -> {:error, {:unknown_plugin, name}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Thin wrapper over the provider registry: the saved
  # [fermix_core.oauth.<provider>] client config plus the plugin's manifest
  # scopes and any caller port override.
  defp oauth_provider(%Plugin{} = plugin, opts) do
    provider = plugin.auth.provider

    client_config =
      provider
      |> to_string()
      |> Config.oauth_provider()
      |> Keyword.put(:scopes, plugin.auth.scopes)
      |> maybe_put(:redirect_port, Keyword.get(opts, :port))

    OAuthProviders.definition(provider, client_config)
  end

  defp flow_opts(opts) do
    []
    |> maybe_put(:port, Keyword.get(opts, :port))
    |> maybe_put(:timeout_ms, Keyword.get(opts, :timeout_ms))
    |> maybe_put(:req_options, Keyword.get(opts, :req_options))
    |> maybe_put(:userinfo_req_options, Keyword.get(opts, :userinfo_req_options))
    |> maybe_put(:puts, Keyword.get(opts, :puts))
    |> maybe_put_opener(opts)
  end

  defp maybe_put_opener(flow_opts, opts) do
    cond do
      Keyword.get(opts, :no_browser, false) ->
        Keyword.put(flow_opts, :opener, nil)

      Keyword.has_key?(opts, :opener) ->
        Keyword.put(flow_opts, :opener, Keyword.get(opts, :opener))

      true ->
        flow_opts
    end
  end

  defp granted_scopes(%{scope: scope}, provider, _requested)
       when is_binary(scope) and scope != "" do
    split_scopes(scope, provider.scope_delimiter)
  end

  defp granted_scopes(_tokens, _provider, requested), do: requested

  defp split_scopes(scope, ","),
    do: scope |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp split_scopes(scope, " "), do: String.split(scope, ~r/\s+/, trim: true)

  # The grant as it will be stored: the tokens the exchange minted, and — for a
  # regional provider — the account's own region confirmed against the one the
  # sign-in client chose.
  defp minted_entry(plugin, provider, tokens, opts) do
    plugin
    |> entry_from_tokens(provider, tokens)
    |> confirm_region(provider, tokens, opts)
  end

  # A sign-in is the one moment the account's region can be learned, and the
  # region the operator chose is what every later call uses as its host. Tesla
  # refuses a call from the wrong region with 421, so the two are compared here
  # and a mismatch is recorded on the grant: the plugin row then says what to
  # fix instead of the first tool call relaying a 421 nobody can act on.
  #
  # Best-effort, exactly like the userinfo fetch: the grant is real either way,
  # so a probe that cannot answer is logged and the sign-in stands.
  defp confirm_region(entry, %OAuthProvider{region_probe: nil}, _tokens, _opts), do: entry

  defp confirm_region(entry, %OAuthProvider{} = provider, tokens, opts) do
    req_options = Keyword.get(opts, :region_req_options, [])

    case probe_region(provider, tokens.access_token, req_options) do
      {:ok, region} -> settle_region(entry, provider.region, region)
      {:wrong_region, region} -> mark_wrong_region(entry, region)
      {:error, reason} -> keep_unconfirmed(entry, reason)
    end
  end

  defp probe_region(%OAuthProvider{region_probe: probe} = provider, access_token, req_options) do
    request =
      Req.new(
        method: :get,
        url: probe.url,
        headers: [{"authorization", "Bearer #{access_token}"}],
        redirect: false
      )

    case request |> Req.merge(req_options) |> Req.request() do
      {:ok, %{status: 200, body: body}} when is_map(body) -> region_at(body, probe.path)
      {:ok, %{status: 421, body: body}} -> {:wrong_region, refused_region(provider, body)}
      {:ok, %{status: status}} -> {:error, {:region_probe_failed, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp region_at(body, path) do
    case get_in(body, path) do
      region when is_binary(region) and region != "" -> {:ok, region}
      _unreadable -> {:error, {:region_probe_unreadable, path}}
    end
  end

  # Tesla names the right base URL in its own 421 text; the registry owns the
  # mapping back to a region id, and answers nil for a URL it does not publish.
  defp refused_region(%OAuthProvider{id: id}, body) do
    OAuthProviders.region_for_base_url(Atom.to_string(id), refusal_text(body))
  end

  defp refusal_text(%{"error" => text}) when is_binary(text), do: text
  defp refusal_text(body) when is_binary(body), do: body
  defp refusal_text(_body), do: ""

  defp settle_region(entry, chosen, chosen), do: entry
  defp settle_region(entry, _chosen, actual), do: mark_wrong_region(entry, actual)

  defp mark_wrong_region(entry, actual),
    do: %{entry | status: "wrong_region", region_actual: actual}

  defp keep_unconfirmed(entry, reason) do
    Logger.warning("Plugins.Auth: the account region check failed: #{Redaction.format(reason)}")
    entry
  end

  defp login_tag(%{status: "wrong_region"}), do: :wrong_region
  defp login_tag(_entry), do: :ready

  defp entry_from_tokens(plugin, provider, tokens) do
    %{
      auth_mode: "oauth2",
      provider: plugin.auth.provider,
      account: account_from_userinfo(Map.get(tokens, :userinfo)),
      granted_scopes: granted_scopes(tokens, provider, plugin.auth.scopes),
      tokens: %{
        access_token: tokens.access_token,
        refresh_token: tokens.refresh_token
      },
      expires_at: tokens.expires_at,
      last_refresh: DateTime.utc_now(),
      status: "ready",
      # The provider's region, for the providers whose API is regional (Tesla's
      # Fleet API). It is knowable only here, while the grant is minted: the
      # refresh path and the plugin's HTTP host read it back off the entry.
      region: provider.region,
      # The account's own region, filled in by `confirm_region/4` only when it
      # disagrees with the one above.
      region_actual: nil
    }
  end

  defp account_from_userinfo(%{} = userinfo) do
    %{
      subject: Map.get(userinfo, "sub"),
      email: Map.get(userinfo, "email"),
      display_name: Map.get(userinfo, "name")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Enum.into(%{})
  end

  defp account_from_userinfo(_userinfo), do: nil

  defp reload_token_manager(plugin) do
    _ = TokenManager.reload(Config.default_auth_profile(plugin))
    :ok
  end

  defp reload_runtime do
    case Runtime.reload() do
      {:ok, _summary} -> :ok
      {:error, reason} -> {:error, {:runtime_reload_failed, reason}}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Every op reports once: the event for the trace and, when it failed, one log
  # line with its class. Neither carries the raw reason, which can hold the
  # authorize url; a refused sign-in client adds the vendor's own words.
  defp report(op, plugin, {:error, reason} = outcome, started_at) do
    Logger.warning(
      "Plugins.Auth: #{op} #{plugin} failed (#{AuthTelemetry.error_class(reason)})" <>
        vendor_words(reason)
    )

    AuthTelemetry.emit(op, plugin, outcome, started_at)
  end

  defp report(op, plugin, {:ok, _tag} = outcome, started_at),
    do: AuthTelemetry.emit(op, plugin, outcome, started_at)

  defp vendor_words({:oauth_client_rejected, detail}),
    do: ": " <> ClientRejection.vendor_words(detail)

  defp vendor_words(_reason), do: ""
end
