defmodule FermixCore.Auth.RefreshClient do
  @moduledoc """
  Bare HTTP refresh against OAuth token endpoints.

  Keeps OpenAI Codex and plugin-provider refresh requests in one place.
  """

  require Logger

  alias FermixCore.Auth.JwtClaims
  alias FermixCore.Auth.OAuthProvider
  alias FermixCore.Auth.Redaction

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @token_url "https://auth.openai.com/oauth/token"
  @max_attempts 3
  @retry_base_ms 350

  @type tokens :: %{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          expires_at: DateTime.t() | nil
        }

  @spec refresh(String.t(), keyword()) :: {:ok, tokens()} | {:error, term()}
  def refresh(refresh_token, req_options \\ []) when is_binary(refresh_token) do
    do_refresh(refresh_token, req_options, 1)
  end

  @spec refresh(OAuthProvider.t(), String.t(), keyword()) :: {:ok, tokens()} | {:error, term()}
  def refresh(%OAuthProvider{} = provider, refresh_token, req_options)
      when is_binary(refresh_token) and is_list(req_options) do
    do_refresh(provider, refresh_token, req_options, 1)
  end

  defp do_refresh(refresh_token, req_options, attempt) do
    body =
      URI.encode_query(%{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => @client_id
      })

    request =
      Req.new(
        url: @token_url,
        method: :post,
        body: body,
        headers: [{"content-type", "application/x-www-form-urlencoded"}]
      )

    case request |> Req.merge(req_options) |> Req.request() do
      {:ok, %{status: 200, body: body}} ->
        parse_token_response(body)

      # 4xx is permanent — the OAuth server told us exactly what's wrong
      # (refresh_token_reused, invalid_grant, etc.). Retrying with the
      # same dead refresh token can never succeed.
      {:ok, %{status: status, body: body}} when status >= 400 and status < 500 ->
        {:error, {:permanent, status, body}}

      {:ok, %{status: status}} when attempt < @max_attempts ->
        Logger.warning("RefreshClient: attempt #{attempt}/#{@max_attempts} got #{status}")
        Process.sleep(@retry_base_ms * attempt)
        do_refresh(refresh_token, req_options, attempt + 1)

      {:ok, %{status: status, body: body}} ->
        {:error, "Refresh failed (#{status}): #{Redaction.format(body)}"}

      {:error, _reason} when attempt < @max_attempts ->
        Logger.warning("RefreshClient: attempt #{attempt}/#{@max_attempts} failed")
        Process.sleep(@retry_base_ms * attempt)
        do_refresh(refresh_token, req_options, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_refresh(%OAuthProvider{} = provider, refresh_token, req_options, attempt) do
    body =
      %{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => provider.client_id
      }
      |> maybe_put("client_secret", provider.client_secret)
      |> URI.encode_query()

    request =
      Req.new(
        url: provider.token_url,
        method: :post,
        body: body,
        headers: [{"content-type", "application/x-www-form-urlencoded"}]
      )

    case request |> Req.merge(req_options) |> Req.request() do
      {:ok, %{status: 200, body: body}} ->
        parse_token_response(body)

      {:ok, %{status: status, body: body}} when status >= 400 and status < 500 ->
        {:error, {:permanent, status, body}}

      {:ok, %{status: status}} when attempt < @max_attempts ->
        Logger.warning("RefreshClient: attempt #{attempt}/#{@max_attempts} got #{status}")
        Process.sleep(@retry_base_ms * attempt)
        do_refresh(provider, refresh_token, req_options, attempt + 1)

      {:ok, %{status: status, body: body}} ->
        {:error, "Refresh failed (#{status}): #{Redaction.format(body)}"}

      {:error, _reason} when attempt < @max_attempts ->
        Logger.warning("RefreshClient: attempt #{attempt}/#{@max_attempts} failed")
        Process.sleep(@retry_base_ms * attempt)
        do_refresh(provider, refresh_token, req_options, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, _key, ""), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  defp parse_token_response(%{"access_token" => access} = body) when is_binary(access) do
    expires_at =
      case body["expires_in"] do
        secs when is_integer(secs) and secs > 0 ->
          DateTime.add(DateTime.utc_now(), secs, :second)

        # xAI omits expires_in; derive from the JWT exp claim (§6.4).
        _ ->
          JwtClaims.expires_at(access)
      end

    {:ok,
     %{
       access_token: access,
       refresh_token: body["refresh_token"],
       expires_at: expires_at
     }}
  end

  defp parse_token_response(_body), do: {:error, :invalid_token_response}
end
