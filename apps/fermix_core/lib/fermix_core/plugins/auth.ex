defmodule FermixCore.Plugins.Auth do
  @moduledoc """
  OAuth login, refresh, and disconnect operations for plugins.
  """

  alias FermixCore.Auth.OAuthFlow
  alias FermixCore.Auth.OAuthProvider
  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenManager
  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.Plugins.Config
  alias FermixCore.Plugins.Plugin
  alias FermixCore.Plugins.Registry
  alias FermixCore.Plugins.Runtime
  alias FermixCore.Plugins.Status

  @spec login(String.t(), keyword()) :: {:ok, Store.entry()} | {:error, term()}
  def login(name, opts \\ []) when is_binary(name) and is_list(opts) do
    started_at = System.monotonic_time(:millisecond)

    with {:ok, plugin} <- fetch_oauth_plugin(name),
         {:ok, scope_profile} <- resolve_scope_profile(plugin, opts),
         {:ok, provider} <- oauth_provider(plugin, scope_profile, opts),
         {:ok, tokens} <- OAuthFlow.start_loopback(provider, flow_opts(opts)),
         {:ok, granted_scopes} <- validate_granted_scopes(plugin, scope_profile, tokens),
         entry <- entry_from_tokens(plugin, scope_profile, granted_scopes, tokens),
         :ok <- Store.write(Config.default_auth_profile(plugin), entry),
         {:ok, _snapshot} <- Config.enable(plugin.name, scope_profile: scope_profile) do
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

  defp resolve_scope_profile(plugin, opts) do
    scope_profile = Keyword.get(opts, :scope_profile) || Config.configured_scope(plugin)

    if scope_profile in plugin.scope_profiles do
      {:ok, scope_profile}
    else
      {:error, {:unknown_scope_profile, plugin.name, scope_profile}}
    end
  end

  defp oauth_provider(%Plugin{auth: %{provider: "google"}} = plugin, scope_profile, opts) do
    config = Config.oauth_provider("google")
    client_id = Keyword.get(config, :client_id)

    cond do
      Keyword.get(config, :client_type, "desktop_public_pkce") != "desktop_public_pkce" ->
        {:error, {:invalid_oauth_client_type, "google", Keyword.get(config, :client_type)}}

      is_binary(client_id) and client_id != "" ->
        {:ok,
         OAuthProvider.google(
           client_id: client_id,
           client_secret: Keyword.get(config, :client_secret),
           redirect_host: Keyword.get(config, :redirect_host, "127.0.0.1"),
           redirect_port: Keyword.get(opts, :port) || Keyword.get(config, :redirect_port, 1455),
           scopes: Status.required_scopes(plugin, scope_profile)
         )}

      true ->
        {:error, :needs_client_config}
    end
  end

  defp oauth_provider(%Plugin{} = plugin, _scope_profile, _opts) do
    {:error, {:unsupported_oauth_provider, plugin.auth.provider}}
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

  defp validate_granted_scopes(plugin, scope_profile, tokens) do
    required = Status.required_scopes(plugin, scope_profile)
    granted = granted_scopes(tokens, required)

    if MapSet.subset?(MapSet.new(required), MapSet.new(granted)) do
      {:ok, granted}
    else
      {:error, {:insufficient_scope, required, granted}}
    end
  end

  defp granted_scopes(%{scope: scope}, _requested) when is_binary(scope) and scope != "" do
    String.split(scope, ~r/\s+/, trim: true)
  end

  defp granted_scopes(_tokens, requested), do: requested

  defp entry_from_tokens(plugin, scope_profile, granted_scopes, tokens) do
    %{
      auth_mode: "oauth2",
      provider: plugin.auth.provider,
      account: account_from_userinfo(Map.get(tokens, :userinfo)),
      scope_profile: scope_profile,
      granted_scopes: granted_scopes,
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
