defmodule FermixCore.Auth.XAILogin do
  @moduledoc """
  xAI Grok Build subscription OAuth — Authorization Code + PKCE over the
  local loopback redirect (design doc §6.4).

  Persists tokens under the `xai_oauth` profile with `provider: "xai"` so
  the TokenSupervisor/TokenManager refresh dispatch keys on it, and
  `status: "ready"` so a re-login clears a stale quarantine.

  The token endpoint is validated before any flow runs (HTTPS, host apex
  or suffix `.x.ai`) — MITM hardening from the Hermes port. xAI access
  tokens are JWTs and the token response may omit `expires_in`;
  `OAuthFlow.parse_token_response` derives expiry from the `exp` claim.
  """

  alias FermixCore.Auth.OAuthFlow
  alias FermixCore.Auth.OAuthProvider
  alias FermixCore.Auth.Store

  require Logger

  @auth_profile "xai_oauth"

  @type opts :: [
          provider: OAuthProvider.t(),
          fermix_path: Path.t(),
          no_browser: boolean(),
          opener: (String.t() -> :ok | {:error, term()}),
          timeout_ms: pos_integer(),
          port_fallbacks: non_neg_integer(),
          req_options: keyword(),
          puts: (String.t() -> any())
        ]

  @spec login(opts()) :: {:ok, Store.entry()} | {:error, term()}
  def login(opts \\ []) when is_list(opts) do
    provider = Keyword.get_lazy(opts, :provider, fn -> OAuthProvider.xai() end)
    fermix_path = Keyword.get(opts, :fermix_path, Store.path())

    with :ok <- validate_token_endpoint(provider.token_url),
         {:ok, tokens} <- OAuthFlow.start_loopback(provider, flow_opts(opts)),
         entry = entry_from_tokens(tokens),
         :ok <- persist(entry, fermix_path) do
      {:ok, entry}
    end
  end

  defp flow_opts(opts) do
    flow = Keyword.take(opts, [:port, :opener, :timeout_ms, :port_fallbacks, :req_options, :puts])

    # `--no-browser` prints the URL instead of launching a browser.
    if Keyword.get(opts, :no_browser, false) do
      Keyword.put(flow, :opener, nil)
    else
      flow
    end
  end

  defp persist(entry, fermix_path) do
    case Store.write(@auth_profile, entry, fermix_path) do
      :ok ->
        Logger.info("XAILogin: persisted oauth_pkce credentials to #{fermix_path}")
        :ok

      {:error, reason} ->
        {:error, {:persist_failed, reason}}
    end
  end

  defp entry_from_tokens(tokens) do
    %{
      auth_mode: "oauth_pkce",
      provider: "xai",
      tokens: %{access_token: tokens.access_token, refresh_token: tokens.refresh_token},
      expires_at: tokens.expires_at,
      last_refresh: DateTime.utc_now(),
      # Explicit "ready" clears a stale quarantine on re-login (Store
      # merges over the existing entry and drops nil keys).
      status: "ready"
    }
  end

  # MITM hardening (design doc §6.4): never POST an auth code to a token
  # endpoint outside x.ai or over plain HTTP.
  defp validate_token_endpoint(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme != "https" -> {:error, {:insecure_token_endpoint, url}}
      not xai_host?(uri.host) -> {:error, {:untrusted_token_endpoint, url}}
      true -> :ok
    end
  end

  defp xai_host?(host) when is_binary(host),
    do: host == "x.ai" or String.ends_with?(host, ".x.ai")

  defp xai_host?(_host), do: false
end
