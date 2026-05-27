defmodule FermixCore.Plugins.Status do
  @moduledoc """
  Local readiness checks for configured plugins.
  """

  alias FermixCore.Auth.Store
  alias FermixCore.Plugins.Config
  alias FermixCore.Plugins.Plugin

  @spec status(Plugin.t()) :: atom()
  def status(%Plugin{} = plugin) do
    cond do
      plugin.name not in Config.enabled_plugins() ->
        :not_configured

      plugin.auth.type == :none ->
        :ready

      missing_client_config?(plugin) ->
        :needs_client_config

      true ->
        auth_status(plugin)
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

  defp missing_client_config?(%Plugin{auth: %{provider: "google", type: :oauth2}}) do
    config = Config.oauth_provider("google")
    blank?(Keyword.get(config, :client_id)) or blank?(Keyword.get(config, :client_secret))
  end

  defp missing_client_config?(_plugin), do: false

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
