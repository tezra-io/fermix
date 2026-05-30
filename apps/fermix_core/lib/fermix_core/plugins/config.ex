defmodule FermixCore.Plugins.Config do
  @moduledoc """
  Persists plugin enablement and provider client configuration.
  """

  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.Plugins.Plugin
  alias FermixCore.Plugins.Registry
  alias FermixCore.Plugins.Runtime
  alias FermixCore.Setup.ConfigStore

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

  defp update_plugins(snapshot, fun) when is_function(fun, 1) do
    fermix_core = Map.get(snapshot, :fermix_core, [])
    plugins = fermix_core |> Keyword.get(:plugins, []) |> fun.()
    Map.put(snapshot, :fermix_core, Keyword.put(fermix_core, :plugins, plugins))
  end

  defp enable_plugin(plugins, plugin) do
    enabled = plugins |> Keyword.get(:enabled, []) |> add_enabled(plugin.name)

    entries =
      plugins
      |> Keyword.get(:entries, %{})
      |> Map.put(plugin.name, plugin_config(plugin))

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

  defp plugin_config(%Plugin{auth: %{type: :none}}), do: []

  defp plugin_config(%Plugin{} = plugin) do
    [auth_profile: default_auth_profile(plugin)]
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

  defp normalize_oauth_provider("google" = provider, opts) do
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

  defp normalized_oauth_provider(opts, client_type) do
    [
      client_type: client_type,
      client_id: Keyword.get(opts, :client_id),
      client_secret: Keyword.get(opts, :client_secret),
      redirect_host: Keyword.get(opts, :redirect_host, "127.0.0.1"),
      redirect_port: Keyword.get(opts, :redirect_port, 1455)
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
    with :ok <- ConfigStore.save_snapshot(snapshot),
         :ok <- ConfigStore.apply_snapshot(snapshot) do
      reload_runtime()
      {:ok, ConfigStore.current_snapshot()}
    end
  end

  defp reload_runtime do
    case Runtime.reload() do
      {:ok, _summary} ->
        :ok

      {:error, reason} ->
        Logger.warning("Plugin runtime reload failed after config change: #{inspect(reason)}")
    end

    :ok
  end

  defp stop_refresh_if_unused({:ok, snapshot}, auth_profile) do
    TokenSupervisor.stop_profile(auth_profile)
    {:ok, snapshot}
  end

  defp stop_refresh_if_unused({:error, _reason} = err, _auth_profile), do: err
end
