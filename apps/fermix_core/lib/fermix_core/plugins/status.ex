defmodule FermixCore.Plugins.Status do
  @moduledoc """
  Local readiness checks for configured plugins.
  """

  alias FermixCore.Auth.Store
  alias FermixCore.Plugins.Config
  alias FermixCore.Plugins.Plugin

  @spec status(Plugin.t(), String.t() | nil) :: atom()
  def status(%Plugin{} = plugin, scope_profile \\ nil) do
    cond do
      plugin.name not in Config.enabled_plugins() ->
        :not_configured

      plugin.auth.type == :none ->
        :ready

      missing_client_config?(plugin) ->
        :needs_client_config

      true ->
        auth_status(plugin, scope_profile || Config.configured_scope(plugin))
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

  @spec required_scopes(Plugin.t(), String.t()) :: [String.t()]
  def required_scopes(%Plugin{auth: %{type: :none}}, _scope_profile), do: []

  def required_scopes(%Plugin{} = plugin, scope_profile) do
    plugin.auth
    |> Map.get(:scope_profiles, %{})
    |> Map.get(scope_profile, %{})
    |> Map.get("scopes", [])
    |> Enum.filter(&is_binary/1)
  end

  @spec scope_satisfies?(Plugin.t(), String.t(), String.t()) :: boolean()
  def scope_satisfies?(%Plugin{} = plugin, selected_profile, required_profile) do
    selected = MapSet.new(required_scopes(plugin, selected_profile))
    required = MapSet.new(required_scopes(plugin, required_profile))
    MapSet.subset?(required, selected)
  end

  defp missing_client_config?(%Plugin{auth: %{provider: "google", type: :oauth2}}) do
    Config.oauth_provider("google")
    |> Keyword.get(:client_id)
    |> blank?()
  end

  defp missing_client_config?(_plugin), do: false

  defp auth_status(plugin, scope_profile) do
    auth_profile = Config.auth_profile(plugin)
    required = required_scopes(plugin, scope_profile)

    case Store.read(auth_profile) do
      {:ok, %{status: "reauthorization_required"}} ->
        :reauthorization_required

      {:ok, %{status: "invalidated"}} ->
        :reauthorization_required

      {:ok, entry} ->
        if scopes_granted?(entry, required), do: :ready, else: :needs_auth

      {:error, {:provider_missing, _profile}} ->
        :needs_auth

      {:error, :no_auth_file} ->
        :needs_auth

      {:error, _reason} ->
        :error
    end
  end

  defp scopes_granted?(_entry, []), do: true

  defp scopes_granted?(entry, required) do
    granted = entry |> Map.get(:granted_scopes, []) |> MapSet.new()
    required |> MapSet.new() |> MapSet.subset?(granted)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
