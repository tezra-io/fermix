defmodule FermixCore.Auth.OAuthProvider do
  @moduledoc """
  Provider configuration for Authorization Code + PKCE flows.
  """

  @type t :: %__MODULE__{
          id: atom(),
          display_name: String.t() | nil,
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
          fixed_port?: boolean(),
          client_rejection_errors: [String.t()],
          region: String.t() | nil,
          extra_token_params: %{optional(String.t()) => String.t()},
          public_redirect_uri: String.t() | nil,
          region_probe: %{url: String.t(), path: [String.t()]} | nil,
          extra_refresh_params: %{optional(String.t()) => String.t()},
          client_registration: :static | :register | :issued,
          hardened_callback?: boolean()
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
  # Keep the OAuth client secret out of any inspect()/log output — one stray
  # `inspect(provider)` in an error path would otherwise leak it in plaintext.
  @derive {Inspect, except: [:client_secret]}
  defstruct [
    :id,
    # The provider's name as operators know it ("X", "Google"). Plugin providers
    # carry it for the refused-client sentences; the built-in providers leave it
    # nil because none of their refusals is classified.
    :display_name,
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
    fixed_port?: false,
    # Token-endpoint `error` codes meaning the provider refused the client (id
    # and secret) the operator saved for it — see `Auth.ClientRejection`. Empty
    # for the built-in providers: their clients are Fermix's own, not the
    # operator's, so no refusal of theirs is reclassified.
    client_rejection_errors: [],
    # An opaque provider-region label recorded on the auth entry at sign-in, for
    # the providers whose API is regional (Tesla). The region is knowable only
    # while the grant is being minted, so nothing downstream can re-derive it.
    # `nil` for every provider that has no regions.
    region: nil,
    # Extra form fields for the AUTHORIZATION_CODE EXCHANGE ONLY, never for
    # refresh: Tesla's exchange is refused without an `audience` naming its
    # region's Fleet API base URL, while its documented refresh form has none.
    # The exchange's own fields win over these — see `OAuthFlow.exchange_code/5`.
    extra_token_params: %{},
    # The registered redirect URI, when it is not the loopback URL the listener
    # binds. Tesla accepts only public https redirect URIs, so the registered one
    # is a static bounce page that forwards the callback query string to the
    # loopback listener: this URI is what authorize and exchange send, while the
    # listener still binds `redirect_host`/`redirect_port` locally.
    public_redirect_uri: nil,
    # How a sign-in asks a regional provider which region the account itself is
    # in: the `url` to GET with the fresh access token, and the `path` its JSON
    # answers the region id under. The region the operator chose is confirmed
    # against that answer before the grant is stored, so a mismatch is recorded
    # on the entry instead of surfacing as a refusal on the first tool call.
    # `nil` for every provider that has no regions.
    region_probe: nil,
    # Extra form fields for the REFRESH grant only. ChatGPT names its
    # `resource` on every token request; no other provider sends any.
    extra_refresh_params: %{},
    # Where the client id comes from. `:static`: it is this struct's own, and
    # the callback says nothing about it. `:register`: `client_id` is a
    # registration entry point and the callback must name the client it issued.
    # `:issued`: `client_id` was issued earlier; the callback may omit it but
    # never name another.
    client_registration: :static,
    # The callback listener accepts only `GET` with `Host` exactly
    # `redirect_host:port` and the exact `redirect_path`, and answers a request
    # with a wrong or missing `state` 400 without ending the sign-in.
    hardened_callback?: false
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

  @chatgpt_resource "https://api.openai.com/v1"
  @chatgpt_scopes ~w(openid profile email offline_access resource.invoke chatgpt.tokens.use.direct)

  @doc """
  Sign in with ChatGPT (M57). `:client_id` is the client OpenAI issued this
  home (`nil` before the first registration, which then goes through
  `dynamic_agent_client` with the `Fermix` name hint). The authorize request
  also carries `:host_id` (`ext_agent_host_id`), the attempt's `:nonce`, and
  `prompt=consent` when `:consent?` is true; a struct built only to refresh
  needs none of them. Port 0 lets the OS choose unless `:port` pins one, and a
  pinned port that is taken fails loud.
  """
  @spec chatgpt(keyword()) :: t()
  def chatgpt(opts) when is_list(opts) do
    client_id = Keyword.fetch!(opts, :client_id)

    %__MODULE__{
      id: :chatgpt,
      display_name: "ChatGPT",
      authorize_url: "https://auth.openai.com/api/accounts/authorize",
      token_url: "https://auth.openai.com/api/accounts/oauth/token",
      client_id: client_id || "dynamic_agent_client",
      client_registration: if(client_id, do: :issued, else: :register),
      redirect_host: "127.0.0.1",
      redirect_port: Keyword.get(opts, :port, 0),
      redirect_path: "/auth/callback",
      scopes: @chatgpt_scopes,
      extra_authorize_params: chatgpt_authorize_params(client_id, opts),
      extra_token_params: %{"resource" => @chatgpt_resource},
      extra_refresh_params: %{"resource" => @chatgpt_resource},
      fixed_port?: true,
      hardened_callback?: true
    }
  end

  defp chatgpt_authorize_params(client_id, opts) do
    %{"resource" => @chatgpt_resource}
    |> put_present("ext_agent_host_id", Keyword.get(opts, :host_id))
    |> put_present("nonce", Keyword.get(opts, :nonce))
    |> put_present("agent_name_hint", if(is_nil(client_id), do: "Fermix"))
    |> put_present("prompt", if(Keyword.get(opts, :consent?, false), do: "consent"))
  end

  defp generate_nonce do
    24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
