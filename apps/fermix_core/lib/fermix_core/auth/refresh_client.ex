defmodule FermixCore.Auth.RefreshClient do
  @moduledoc """
  Bare HTTP refresh against the OpenAI token endpoint.

  Used by both `FermixCore.Auth.TokenManager` (scheduled refreshes against
  the Fermix-owned auth profile) and `FermixCore.Auth.CodexImport` (the
  one-shot refresh that mints Fermix-owned tokens from a Codex CLI
  refresh token). Keeps the HTTP shape in one place so the two callers
  cannot drift.
  """

  require Logger

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

      {:ok, %{status: status}} when attempt < @max_attempts ->
        Logger.warning("RefreshClient: attempt #{attempt}/#{@max_attempts} got #{status}")
        Process.sleep(@retry_base_ms * attempt)
        do_refresh(refresh_token, req_options, attempt + 1)

      {:ok, %{status: status, body: body}} ->
        {:error, "Refresh failed (#{status}): #{inspect(body)}"}

      {:error, _reason} when attempt < @max_attempts ->
        Logger.warning("RefreshClient: attempt #{attempt}/#{@max_attempts} failed")
        Process.sleep(@retry_base_ms * attempt)
        do_refresh(refresh_token, req_options, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_token_response(%{"access_token" => access} = body) when is_binary(access) do
    expires_at =
      case body["expires_in"] do
        secs when is_integer(secs) and secs > 0 ->
          DateTime.add(DateTime.utc_now(), secs, :second)

        _ ->
          nil
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
