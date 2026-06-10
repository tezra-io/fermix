defmodule FermixCore.Auth.OAuthProviders do
  @moduledoc """
  Registry of plugin OAuth providers, keyed by the manifest's `auth.provider`.

  Each definition combines the provider's fixed endpoint data with the
  operator's `[fermix_core.oauth.<provider>]` client config (client_id,
  client_secret, optional redirect host/port). Login (`Plugins.Auth`) and
  refresh (`TokenManager`/`TokenSupervisor`) both resolve providers here —
  one definition per provider, every caller.
  """

  alias FermixCore.Auth.OAuthProvider
  alias FermixCore.Plugins.Config

  @supported_providers ~w(google github notion)

  @type error ::
          {:unsupported_oauth_provider, term()}
          | {:invalid_oauth_client_type, String.t(), term()}
          | :needs_client_config

  @doc """
  Builds the `OAuthProvider` definition for `provider` from the given client
  config (`client_id`, `client_secret`, optional `client_type`,
  `redirect_host`, `redirect_port`, `scopes`).
  """
  @spec definition(term(), keyword()) :: {:ok, OAuthProvider.t()} | {:error, error()}
  def definition(provider, client_config) when is_list(client_config) do
    with :ok <- validate_supported(provider),
         :ok <- validate_client(provider, client_config) do
      {:ok, build(provider, client_config)}
    end
  end

  @doc """
  Builds the definition from the `[fermix_core.oauth.<provider>]` app-env
  client config — the refresh path, where scopes come from the stored entry.
  """
  @spec definition_from_env(String.t(), [String.t()]) ::
          {:ok, OAuthProvider.t()} | {:error, error()}
  def definition_from_env(provider, scopes) when is_binary(provider) and is_list(scopes) do
    definition(provider, Keyword.put(Config.oauth_provider(provider), :scopes, scopes))
  end

  defp validate_supported(provider) when provider in @supported_providers, do: :ok
  defp validate_supported(provider), do: {:error, {:unsupported_oauth_provider, provider}}

  defp validate_client(provider, config) do
    client_type = Keyword.get(config, :client_type, "desktop_public_pkce")

    cond do
      client_type != "desktop_public_pkce" ->
        {:error, {:invalid_oauth_client_type, provider, client_type}}

      present?(Keyword.get(config, :client_id)) and
          present?(Keyword.get(config, :client_secret)) ->
        :ok

      true ->
        {:error, :needs_client_config}
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp build("google", config) do
    %OAuthProvider{
      id: :google,
      authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
      token_url: "https://oauth2.googleapis.com/token",
      userinfo_url: "https://openidconnect.googleapis.com/v1/userinfo",
      client_id: Keyword.fetch!(config, :client_id),
      client_secret: Keyword.get(config, :client_secret),
      redirect_host: Keyword.get(config, :redirect_host, "127.0.0.1"),
      redirect_port: Keyword.get(config, :redirect_port, 1455),
      redirect_path: "/auth/callback",
      scopes: Keyword.get(config, :scopes, []),
      extra_authorize_params: %{"access_type" => "offline", "prompt" => "consent"}
    }
  end

  # GitHub answers form-encoded at the token endpoint unless asked for JSON,
  # and joins granted scopes with commas. Loopback redirect URIs are
  # port-wildcarded, so the engine's port fallback stays available.
  defp build("github", config) do
    %OAuthProvider{
      id: :github,
      authorize_url: "https://github.com/login/oauth/authorize",
      token_url: "https://github.com/login/oauth/access_token",
      userinfo_url: "https://api.github.com/user",
      client_id: Keyword.fetch!(config, :client_id),
      client_secret: Keyword.get(config, :client_secret),
      redirect_host: Keyword.get(config, :redirect_host, "127.0.0.1"),
      redirect_port: Keyword.get(config, :redirect_port, 1457),
      redirect_path: "/auth/callback",
      scopes: Keyword.get(config, :scopes, []),
      token_headers: [{"accept", "application/json"}],
      scope_delimiter: ","
    }
  end

  # Notion requires HTTP Basic client auth at the token endpoint and
  # registers exact-match redirect URIs (port included) — fixed port, no
  # fallback. Its /v1/users/me needs a Notion-Version header the engine does
  # not send, so the best-effort userinfo fetch is skipped (nil URL).
  defp build("notion", config) do
    %OAuthProvider{
      id: :notion,
      authorize_url: "https://api.notion.com/v1/oauth/authorize",
      token_url: "https://api.notion.com/v1/oauth/token",
      userinfo_url: nil,
      client_id: Keyword.fetch!(config, :client_id),
      client_secret: Keyword.get(config, :client_secret),
      redirect_host: Keyword.get(config, :redirect_host, "127.0.0.1"),
      redirect_port: Keyword.get(config, :redirect_port, 1458),
      redirect_path: "/auth/callback",
      scopes: Keyword.get(config, :scopes, []),
      extra_authorize_params: %{"owner" => "user"},
      token_auth: :basic,
      fixed_port?: true
    }
  end
end
