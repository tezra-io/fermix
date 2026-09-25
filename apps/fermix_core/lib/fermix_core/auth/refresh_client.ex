defmodule FermixCore.Auth.RefreshClient do
  @moduledoc """
  Bare HTTP refresh against OAuth token endpoints.

  Keeps OpenAI Codex and plugin-provider refresh requests in one place.

  **Time bound.** A refresh runs under its profile's lock
  (`FermixCore.Auth.Store.with_profile_lock/3`), which another refresher breaks
  once its mtime is 120 s old by the wall clock, so a live refresh must finish
  sooner (a sleep or clock step mid-refresh can still make it look stale). Each
  request sets its own bounds instead of Mint's 30 s connect default: pool 5 s,
  connect 10 s, receive 15 s, and no Req retry (`request_bounds/0`). Three 30 s
  attempts, the 350 ms and 700 ms sleeps and two 8 s store-lock waits come to
  about 107 s (`worst_case_ms/0`, held below the threshold by a test). The
  receive wait bounds each socket read; a token response is one small body. It
  stays at Req's 15 s default: a shorter wait would abandon slow successes, and
  an abandoned success loses a rotation. A sign-in's requests under the same
  lock (the code exchange, the account lookup, a region probe) set the same
  bounds.
  """

  require Logger

  alias FermixCore.Auth.ClientRejection
  alias FermixCore.Auth.JwtClaims
  alias FermixCore.Auth.OAuthProvider
  alias FermixCore.Auth.Redaction

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @token_url "https://auth.openai.com/oauth/token"
  @max_attempts 3
  @retry_base_ms 350

  @pool_timeout_ms 5_000
  @connect_timeout_ms 10_000
  @receive_timeout_ms 15_000

  # The longest one refresh can take: every attempt at its full timeouts, plus
  # the sleeps between them. Public so a test can hold it under the profile
  # lock's stale threshold.
  @doc false
  @spec worst_case_ms() :: pos_integer()
  def worst_case_ms do
    attempt_ms = @pool_timeout_ms + @connect_timeout_ms + @receive_timeout_ms
    sleeps_ms = Enum.sum(for attempt <- 1..(@max_attempts - 1), do: @retry_base_ms * attempt)
    @max_attempts * attempt_ms + sleeps_ms
  end

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
        [
          url: @token_url,
          method: :post,
          body: body,
          headers: [{"content-type", "application/x-www-form-urlencoded"}]
        ] ++ request_bounds()
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
        "refresh_token" => refresh_token
      }
      |> Map.merge(OAuthProvider.body_credentials(provider))
      |> URI.encode_query()

    request =
      Req.new(
        [
          url: provider.token_url,
          method: :post,
          body: body,
          headers: OAuthProvider.token_request_headers(provider)
        ] ++ request_bounds()
      )

    response = request |> Req.merge(req_options) |> Req.request()

    case client_rejection(provider, response) do
      nil -> refresh_response(provider, refresh_token, req_options, attempt, response)
      rejection -> {:error, rejection}
    end
  end

  # A refused client is refused on every attempt and is no dead grant, so it is
  # recognised before the permanent-4xx clause and before a 200 is read as
  # tokens (GitHub and Slack refuse with a 200). Never retried.
  defp client_rejection(provider, {:ok, %{status: status, body: body}})
       when status == 200 or (status >= 400 and status < 500),
       do: ClientRejection.classify(provider, status, body)

  defp client_rejection(_provider, _response), do: nil

  defp refresh_response(provider, refresh_token, req_options, attempt, response) do
    case response do
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

  @doc """
  The bounds every request made under a profile lock sets: pool 5 s, connect
  10 s, receive 15 s, and no Req retry, so each request is one attempt of at
  most 30 s. Req retries a GET on a transient failure up to three more times
  and honours a `Retry-After` of any length, which no lock's stale threshold
  could bound. A refresh does its own bounded retries.
  """
  @spec request_bounds() :: keyword()
  def request_bounds do
    [
      retry: false,
      pool_timeout: @pool_timeout_ms,
      connect_options: [timeout: @connect_timeout_ms],
      receive_timeout: @receive_timeout_ms
    ]
  end

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
