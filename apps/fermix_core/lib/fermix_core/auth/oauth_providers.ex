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

  @supported_providers ~w(google github notion x slack tesla)

  # The one table of operator-facing provider names: the setup page's client
  # forms and every refused-client sentence read it here.
  @display_names %{
    "google" => "Google",
    "github" => "GitHub",
    "notion" => "Notion",
    "x" => "X",
    "slack" => "Slack",
    "tesla" => "Tesla"
  }

  # The one table of Tesla regions: the picker an operator chooses from before
  # connecting, and the Fleet API base URL each choice selects. The base URL is
  # what the authorization-code exchange must send as `audience` and the host
  # every tool then calls, so a region absent from this table has no audience to
  # send and is refused rather than defaulted
  # (https://developer.tesla.com/docs/fleet-api/getting-started/regions-countries).
  # China is absent on purpose: it needs a separate Tesla application and the
  # plugin publishes no host for it.
  @tesla_regions [
    %{
      id: "na",
      label: "North America and Asia-Pacific",
      audience: "https://fleet-api.prd.na.vn.cloud.tesla.com"
    },
    %{
      id: "eu",
      label: "Europe, Middle East and Africa",
      audience: "https://fleet-api.prd.eu.vn.cloud.tesla.com"
    }
  ]
  @tesla_fleet_audiences Map.new(@tesla_regions, &{&1.id, &1.audience})
  # What `GET <audience>/api/1/users/region` answers the account's own region
  # under, so a sign-in can confirm the chosen region against Tesla's own answer.
  @tesla_region_path "/api/1/users/region"
  # Tesla registers exact-match PUBLIC https redirect URIs and accepts no
  # loopback one, so the registered URI is a static bounce page that forwards the
  # callback query string to the daemon's loopback listener.
  @tesla_default_redirect_uri "https://fermix.ai/api/integrations/tesla/callback"

  @type error ::
          {:unsupported_oauth_provider, term()}
          | {:invalid_oauth_client_type, String.t(), term()}
          | {:invalid_oauth_region, String.t(), term()}
          | {:missing_oauth_region, String.t()}
          | :needs_client_config

  @doc "Every plugin OAuth provider this registry defines, ordered."
  @spec providers() :: [String.t()]
  def providers, do: @supported_providers

  @doc "The operator-facing name of one plugin OAuth provider."
  @spec display_name(String.t()) :: String.t()
  def display_name(provider) when provider in @supported_providers,
    do: Map.fetch!(@display_names, provider)

  @doc """
  Builds the `OAuthProvider` definition for `provider` from the given client
  config (`client_id`, `client_secret`, optional `client_type`,
  `redirect_host`, `redirect_port`, `scopes`, and — for the regional Tesla
  provider — `region` and the registered public `redirect_uri`).
  """
  @spec definition(term(), keyword()) :: {:ok, OAuthProvider.t()} | {:error, error()}
  def definition(provider, client_config) when is_list(client_config) do
    with :ok <- validate_supported(provider),
         :ok <- validate_client(provider, client_config),
         :ok <- validate_region(provider, Keyword.get(client_config, :region)) do
      {:ok, build(provider, client_config)}
    end
  end

  @doc """
  The regions a provider offers an operator to choose from before connecting,
  as `%{id, label}` in display order; `[]` for a provider that has one region.
  Tesla is regional: the chosen region is the token-exchange `audience` and the
  Fleet API host every tool calls, and Tesla itself refuses a mismatch with
  421. China is not offered here: it needs a separate application and the
  plugin publishes no host for it.

  This is the one region set. The audience table, `validate_region/2`, the
  sign-in client row on the management wire and the browser door's picker all
  read it, so a region offered in one place and refused in another is not a
  state this registry can reach.
  """
  @spec regions(String.t()) :: [%{id: String.t(), label: String.t()}]
  def regions("tesla"), do: Enum.map(@tesla_regions, &Map.take(&1, [:id, :label]))

  def regions(provider) when provider in @supported_providers, do: []

  @doc """
  The operator-facing label of one of `provider`'s regions, or `nil` when it
  offers no region by that id. One reader, so a row that names the account's
  region and the picker that offers it cannot disagree about its words.

  Unlike `regions/1`, this answers `nil` rather than raising for a provider this
  registry does not define: it renders a value read back off a stored grant,
  which can name any provider a manifest declared, and a name with no regions
  simply has no label to lend.
  """
  @spec region_label(String.t(), term()) :: String.t() | nil
  def region_label(provider, id) when provider in @supported_providers do
    provider
    |> regions()
    |> Enum.find_value(fn region -> if region.id == id, do: region.label end)
  end

  def region_label(provider, _id) when is_binary(provider), do: nil

  @doc """
  The region whose regional base URL `text` names, or `nil`.

  Tesla refuses a call to the wrong region with 421 and names the right base URL
  in its own error text. Reading a region back out of that text is the inverse of
  the audience table above, so it has the table's owner rather than a second copy
  of the URLs at the call site.
  """
  @spec region_for_base_url(String.t(), String.t()) :: String.t() | nil
  def region_for_base_url("tesla", text) when is_binary(text) do
    Enum.find_value(@tesla_fleet_audiences, fn {id, url} ->
      if String.contains?(text, url), do: id
    end)
  end

  def region_for_base_url(provider, text)
      when provider in @supported_providers and is_binary(text),
      do: nil

  @doc """
  Validates one provider's configured `region`, accepting exactly the ids
  `regions/1` publishes.

  Tesla is the only regional provider: its region selects the Fleet API base URL
  the token exchange must name as `audience` and the host every tool then calls,
  and Tesla refuses every call from the wrong region with 421. So the region is
  chosen as part of the sign-in client and there is no default — an unchosen one
  is `{:missing_oauth_region, provider}` and an unoffered one is
  `{:invalid_oauth_region, provider, region}`, kept apart because the operator's
  fix differs.

  The config write path (`Plugins.Config.set_oauth_provider/2`) calls this too,
  so the region set has one owner and a refused value never reaches
  `config.toml`.
  """
  @spec validate_region(String.t(), term()) :: :ok | {:error, error()}
  def validate_region("tesla", region) when is_map_key(@tesla_fleet_audiences, region), do: :ok

  def validate_region("tesla", region), do: {:error, tesla_region_error(region)}

  def validate_region(provider, _region) when provider in @supported_providers, do: :ok

  defp tesla_region_error(region) when is_nil(region), do: {:missing_oauth_region, "tesla"}

  defp tesla_region_error(region) when is_binary(region) do
    if String.trim(region) == "",
      do: {:missing_oauth_region, "tesla"},
      else: {:invalid_oauth_region, "tesla", region}
  end

  defp tesla_region_error(region), do: {:invalid_oauth_region, "tesla", region}

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

  # Google refuses the saved client with `invalid_client`, "The OAuth client
  # secret is incorrect" (https://developers.google.com/identity/protocols/oauth2/web-server,
  # Errors: invalid_client). `unauthorized_client` is deliberately absent:
  # Google answers it when a refresh token was minted for a different client,
  # where signing in again is the fix, not the secret.
  defp build("google", config) do
    %OAuthProvider{
      id: :google,
      display_name: display_name("google"),
      authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
      token_url: "https://oauth2.googleapis.com/token",
      userinfo_url: "https://openidconnect.googleapis.com/v1/userinfo",
      client_id: Keyword.fetch!(config, :client_id),
      client_secret: Keyword.get(config, :client_secret),
      redirect_host: Keyword.get(config, :redirect_host, "127.0.0.1"),
      redirect_port: Keyword.get(config, :redirect_port, 1455),
      redirect_path: "/auth/callback",
      scopes: Keyword.get(config, :scopes, []),
      extra_authorize_params: %{"access_type" => "offline", "prompt" => "consent"},
      client_rejection_errors: ["invalid_client"]
    }
  end

  # GitHub answers form-encoded at the token endpoint unless asked for JSON,
  # and joins granted scopes with commas. Loopback redirect URIs are
  # port-wildcarded, so the engine's port fallback stays available. It refuses
  # the saved client with HTTP 200 and `incorrect_client_credentials`
  # (https://docs.github.com/en/apps/oauth-apps/maintaining-oauth-apps/troubleshooting-oauth-app-access-token-request-errors).
  defp build("github", config) do
    %OAuthProvider{
      id: :github,
      display_name: display_name("github"),
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
      scope_delimiter: ",",
      client_rejection_errors: ["incorrect_client_credentials"]
    }
  end

  # Notion requires HTTP Basic client auth at the token endpoint and
  # registers exact-match redirect URIs (port included) — fixed port, no
  # fallback. Its /v1/users/me needs a Notion-Version header the engine does
  # not send, so the best-effort userinfo fetch is skipped (nil URL). A refused
  # client is 401 `invalid_client`
  # (https://developers.notion.com/reference/create-a-token).
  defp build("notion", config) do
    %OAuthProvider{
      id: :notion,
      display_name: display_name("notion"),
      authorize_url: "https://api.notion.com/v1/oauth/authorize",
      token_url: "https://api.notion.com/v1/oauth/token",
      userinfo_url: nil,
      client_id: Keyword.fetch!(config, :client_id),
      client_secret: Keyword.get(config, :client_secret),
      # Notion forces https for IP-literal redirect URIs but allows http for the
      # `localhost` hostname; the loopback listener still binds 127.0.0.1, which
      # the browser reaches by resolving localhost.
      redirect_host: Keyword.get(config, :redirect_host, "localhost"),
      redirect_port: Keyword.get(config, :redirect_port, 1458),
      redirect_path: "/auth/callback",
      scopes: Keyword.get(config, :scopes, []),
      extra_authorize_params: %{"owner" => "user"},
      token_auth: :basic,
      fixed_port?: true,
      client_rejection_errors: ["invalid_client"]
    }
  end

  # X (api.x.com) is a confidential client — the portal "Web App, Automated App
  # or Bot" type — so the token endpoint takes HTTP Basic client auth (PKCE is
  # still required). Redirect URIs are exact-match including port, and X's portal
  # accepts `http://127.0.0.1` but rejects `localhost` — the inverse of Notion —
  # so the host stays the IP literal with a fixed port. Refresh tokens are
  # single-use and rotated on every refresh; the token managers already persist
  # the rotated pair. /2/users/me returns a `{"data": ...}` envelope the engine's
  # best-effort userinfo fetch does not parse, so it is skipped (the x_whoami
  # tool covers identity). X answers a present but rejected Basic credential
  # (a secret regenerated in its console) with 401 `unauthorized_client`,
  # "Missing valid authorization header", verified live 2026-09-10; a truly
  # absent header is a 400 instead. `invalid_client` is RFC 6749 §5.2's code
  # for the same failed client authentication.
  defp build("x", config) do
    %OAuthProvider{
      id: :x,
      display_name: display_name("x"),
      authorize_url: "https://x.com/i/oauth2/authorize",
      token_url: "https://api.x.com/2/oauth2/token",
      userinfo_url: nil,
      client_id: Keyword.fetch!(config, :client_id),
      client_secret: Keyword.get(config, :client_secret),
      redirect_host: Keyword.get(config, :redirect_host, "127.0.0.1"),
      redirect_port: Keyword.get(config, :redirect_port, 1459),
      redirect_path: "/auth/callback",
      scopes: Keyword.get(config, :scopes, []),
      token_auth: :basic,
      fixed_port?: true,
      client_rejection_errors: ["invalid_client", "unauthorized_client"]
    }
  end

  # Slack OAuth v2: bot scopes go in `scope` (comma-separated) and the token
  # endpoint (`oauth.v2.access`) returns JSON with the bot token at
  # `access_token`. Confidential client (client_secret) with an exact-match
  # fixed redirect URI. User-token methods (search.messages) need a separate
  # `user_scope`/token and are deferred — see M16 §7.1. Slack refuses the saved
  # client with `ok: false` and `invalid_client_id` or `bad_client_secret`
  # (https://docs.slack.dev/reference/methods/oauth.v2.access).
  # Tesla's Fleet API is regional and its authorization-code exchange is refused
  # without an `audience` naming the region's base URL; refresh must not carry
  # one, so it travels as `extra_token_params` (exchange only). The registered
  # redirect URI is public https — Tesla accepts no loopback URI — so a static
  # bounce page forwards the callback to this loopback listener, which still
  # binds `localhost` on a fixed port (the registered URI is exact-match, so
  # there is no port fallback). PKCE is not documented at the token endpoint;
  # the unconditional challenge/verifier is tolerated as an extra parameter.
  # A refused client is `invalid_client`, RFC 6749 §5.2's code for failed client
  # authentication (https://developer.tesla.com/docs/fleet-api/authentication/third-party-tokens).
  defp build("tesla", config) do
    # `definition/2` validated the region, so an absent or unoffered one cannot
    # reach here; fetching it is what keeps that true rather than defaulting.
    region = Keyword.fetch!(config, :region)
    audience = Map.fetch!(@tesla_fleet_audiences, region)

    %OAuthProvider{
      id: :tesla,
      display_name: display_name("tesla"),
      authorize_url: "https://auth.tesla.com/oauth2/v3/authorize",
      token_url: "https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token",
      userinfo_url: nil,
      client_id: Keyword.fetch!(config, :client_id),
      client_secret: Keyword.get(config, :client_secret),
      redirect_host: Keyword.get(config, :redirect_host, "localhost"),
      redirect_port: Keyword.get(config, :redirect_port, 1461),
      redirect_path: "/auth/callback",
      scopes: Keyword.get(config, :scopes, []),
      token_auth: :body,
      fixed_port?: true,
      client_rejection_errors: ["invalid_client"],
      region: region,
      extra_token_params: %{"audience" => audience},
      public_redirect_uri: Keyword.get(config, :redirect_uri) || @tesla_default_redirect_uri,
      region_probe: %{url: audience <> @tesla_region_path, path: ["response", "region"]}
    }
  end

  defp build("slack", config) do
    %OAuthProvider{
      id: :slack,
      display_name: display_name("slack"),
      authorize_url: "https://slack.com/oauth/v2/authorize",
      token_url: "https://slack.com/api/oauth.v2.access",
      userinfo_url: nil,
      client_id: Keyword.fetch!(config, :client_id),
      client_secret: Keyword.get(config, :client_secret),
      redirect_host: Keyword.get(config, :redirect_host, "127.0.0.1"),
      redirect_port: Keyword.get(config, :redirect_port, 1460),
      redirect_path: "/auth/callback",
      scopes: Keyword.get(config, :scopes, []),
      scope_delimiter: ",",
      fixed_port?: true,
      client_rejection_errors: ["invalid_client_id", "bad_client_secret"]
    }
  end
end
