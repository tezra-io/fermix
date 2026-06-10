defmodule FermixCore.Plugins.Auth do
  @moduledoc """
  OAuth login, refresh, and disconnect operations for plugins.
  """

  alias FermixCore.Auth.OAuthFlow
  alias FermixCore.Auth.OAuthProviders
  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.Plugins.Config
  alias FermixCore.Plugins.Plugin
  alias FermixCore.Plugins.Registry
  alias FermixCore.Plugins.Runtime

  @spec login(String.t(), keyword()) :: {:ok, Store.entry()} | {:error, term()}
  def login(name, opts \\ []) when is_binary(name) and is_list(opts) do
    started_at = System.monotonic_time(:millisecond)

    with {:ok, plugin} <- fetch_oauth_plugin(name),
         {:ok, provider} <- oauth_provider(plugin, opts),
         {:ok, tokens} <- OAuthFlow.start_loopback(provider, flow_opts(opts)),
         entry <- entry_from_tokens(plugin, provider, tokens),
         :ok <- Store.write(Config.default_auth_profile(plugin), entry),
         {:ok, _snapshot} <- Config.enable(plugin.name) do
      reload_token_manager(plugin)
      emit_auth_event(:login, plugin.name, entry.status, started_at)
      {:ok, entry}
    else
      {:error, reason} = err ->
        emit_auth_event(:login, name, {:error, reason}, started_at)
        err
    end
  end

  @spec reauthorize(String.t(), keyword()) :: {:ok, Store.entry()} | {:error, term()}
  def reauthorize(name, opts \\ []), do: login(name, opts)

  @spec refresh(String.t()) :: {:ok, String.t()} | {:error, term()}
  def refresh(name) when is_binary(name) do
    started_at = System.monotonic_time(:millisecond)

    with {:ok, plugin} <- Registry.find(name) do
      case TokenManager.refresh(Config.auth_profile(plugin)) do
        {:ok, token} ->
          emit_auth_event(:refresh, plugin.name, "ready", started_at)
          {:ok, token}

        {:error, reason} = err ->
          emit_auth_event(:refresh, plugin.name, {:error, reason}, started_at)
          err
      end
    end
  end

  @spec logout(String.t()) :: :ok | {:error, term()}
  def logout(name) when is_binary(name) do
    started_at = System.monotonic_time(:millisecond)

    with {:ok, plugin} <- Registry.find(name),
         auth_profile <- Config.auth_profile(plugin),
         :ok <- Store.delete_provider(auth_profile) do
      TokenSupervisor.stop_profile(auth_profile)

      case reload_runtime() do
        :ok ->
          emit_auth_event(:logout, plugin.name, "logged_out", started_at)
          :ok

        {:error, reason} = err ->
          emit_auth_event(:logout, plugin.name, {:error, reason}, started_at)
          err
      end
    else
      {:error, reason} = err ->
        emit_auth_event(:logout, name, {:error, reason}, started_at)
        err
    end
  end

  defp fetch_oauth_plugin(name) do
    case Registry.find(name) do
      {:ok, %Plugin{auth: %{type: :oauth2}} = plugin} -> {:ok, plugin}
      {:ok, %Plugin{}} -> {:error, {:auth_not_required, name}}
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
      status: "ready"
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

  defp emit_auth_event(event, plugin, status, started_at) do
    duration = System.monotonic_time(:millisecond) - started_at

    :telemetry.execute(
      [:fermix, :plugin, :auth],
      %{duration_ms: duration},
      %{event: event, plugin: plugin, status: telemetry_status(status)}
    )
  end

  defp telemetry_status({:error, _reason}), do: :error
  defp telemetry_status(status) when is_binary(status), do: status
end
