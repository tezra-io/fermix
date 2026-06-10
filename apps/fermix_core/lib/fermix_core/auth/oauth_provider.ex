defmodule FermixCore.Auth.OAuthProvider do
  @moduledoc """
  Provider configuration for Authorization Code + PKCE flows.
  """

  @type t :: %__MODULE__{
          id: atom(),
          authorize_url: String.t(),
          token_url: String.t(),
          userinfo_url: String.t() | nil,
          client_id: String.t(),
          client_secret: String.t() | nil,
          redirect_host: String.t(),
          redirect_port: :inet.port_number(),
          redirect_path: String.t(),
          scopes: [String.t()],
          extra_authorize_params: map(),
          echo_code_challenge?: boolean(),
          token_headers: [{String.t(), String.t()}],
          token_auth: :body | :basic,
          scope_delimiter: String.t(),
          fixed_port?: boolean()
        }

  @enforce_keys [
    :id,
    :authorize_url,
    :token_url,
    :client_id,
    :redirect_host,
    :redirect_port,
    :redirect_path,
    :scopes
  ]
  defstruct [
    :id,
    :authorize_url,
    :token_url,
    :userinfo_url,
    :client_id,
    :client_secret,
    :redirect_host,
    :redirect_port,
    :redirect_path,
    scopes: [],
    extra_authorize_params: %{},
    # Some token endpoints (xAI) re-validate PKCE and require the
    # code_challenge echoed alongside code_verifier during exchange.
    echo_code_challenge?: false,
    # Extra headers on token-endpoint requests (code exchange + refresh) —
    # GitHub needs {"accept", "application/json"} or it answers form-encoded.
    token_headers: [],
    # How client credentials reach the token endpoint: form body (default)
    # or an HTTP Basic Authorization header (Notion).
    token_auth: :body,
    # Delimiter of the token-response `scope` field (GitHub joins with ",").
    scope_delimiter: " ",
    # Providers with exact-match registered redirect URIs (Notion) must bind
    # the configured port exactly — no port fallback.
    fixed_port?: false
  ]

  @doc """
  Headers for token-endpoint requests (code exchange and refresh): the form
  content type, the provider's extra `token_headers`, and — for `:basic`
  providers — the client credentials as an HTTP Basic Authorization header.
  """
  @spec token_request_headers(t()) :: [{String.t(), String.t()}]
  def token_request_headers(%__MODULE__{} = provider) do
    [{"content-type", "application/x-www-form-urlencoded"}] ++
      provider.token_headers ++ basic_auth_header(provider)
  end

  @doc """
  Client credentials for the token-request form body. Empty for `:basic`
  providers — their credentials travel in the Authorization header instead.
  """
  @spec body_credentials(t()) :: %{optional(String.t()) => String.t()}
  def body_credentials(%__MODULE__{token_auth: :basic}), do: %{}

  def body_credentials(%__MODULE__{} = provider) do
    put_present(%{"client_id" => provider.client_id}, "client_secret", provider.client_secret)
  end

  defp basic_auth_header(%__MODULE__{token_auth: :basic} = provider) do
    credentials = Base.encode64("#{provider.client_id}:#{provider.client_secret}")
    [{"authorization", "Basic " <> credentials}]
  end

  defp basic_auth_header(%__MODULE__{}), do: []

  defp put_present(params, _key, nil), do: params
  defp put_present(params, _key, ""), do: params
  defp put_present(params, key, value), do: Map.put(params, key, value)

  # Reference values from the Hermes port (design doc §5.6) — verify against
  # current Claude Code behavior before shipping native PKCE. The redirect is
  # Anthropic's hosted manual-paste page, NOT a localhost loopback; refresh
  # uses only :token_url + :client_id.
  @spec anthropic() :: t()
  def anthropic do
    %__MODULE__{
      id: :anthropic,
      authorize_url: "https://claude.ai/oauth/authorize",
      token_url: "https://console.anthropic.com/v1/oauth/token",
      client_id: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
      redirect_host: "console.anthropic.com",
      redirect_port: 443,
      redirect_path: "/oauth/code/callback",
      scopes: ["org:create_api_key", "user:profile", "user:inference"]
    }
  end

  # Reference values from the Hermes port (design doc §6.4) — verify against
  # current xAI / Grok Build behavior before the first live login.
  # `plan=generic` is required for non-allowlisted loopback OAuth; the OIDC
  # `nonce` is generated per struct build (one login flow per struct).
  @spec xai(keyword()) :: t()
  def xai(opts \\ []) when is_list(opts) do
    %__MODULE__{
      id: :xai,
      authorize_url: "https://auth.x.ai/oauth2/authorize",
      token_url: "https://auth.x.ai/oauth2/token",
      client_id: "b1a00492-073a-47ea-816f-4c329264a828",
      redirect_host: Keyword.get(opts, :redirect_host, "127.0.0.1"),
      redirect_port: Keyword.get(opts, :redirect_port, 56_121),
      redirect_path: Keyword.get(opts, :redirect_path, "/callback"),
      scopes: ~w(openid profile email offline_access grok-cli:access api:access),
      extra_authorize_params: %{
        "plan" => "generic",
        "nonce" => Keyword.get_lazy(opts, :nonce, &generate_nonce/0)
      },
      echo_code_challenge?: true
    }
  end

  defp generate_nonce do
    24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
