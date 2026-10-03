defmodule FermixCore.Auth.ChatGPT.Logout do
  @moduledoc """
  Signs this home out of ChatGPT (M57 §6.3): revokes the renewable session
  upstream, then clears the tokens and keeps the registration (client id,
  subject, email, granted scopes), so the next sign-in reuses the client.

  The revoke is a form `POST` of the refresh token with its issued client id.
  Any 200 means revoked, including a token that was already invalid. A 5xx or a
  network failure is retried twice with backoff; when revocation is still not
  confirmed the tokens are cleared anyway and the result says
  `revoked: false`. All of it runs under the profile lock, so no refresh
  rotates the token between its read and its revoke, and the lock's bound
  holds (`worst_case_ms/0`).
  """

  alias FermixCore.Auth.ChatGPT.Registration
  alias FermixCore.Auth.Redaction
  alias FermixCore.Auth.RefreshClient
  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.Net.Egress

  require Logger

  @revoke_url "https://auth.openai.com/api/accounts/oauth/revoke"
  @attempts 3
  @retry_base_ms 350

  @doc """
  Revokes, clears, and makes a running token manager let go of the profile.
  Options: `:fermix_path`, `:req_options` (with `:retry_sleep`, a one-argument
  function replacing `Process.sleep/1` between attempts, as a test seam).
  """
  @spec run(keyword()) :: {:ok, %{revoked: boolean()}} | {:error, term()}
  def run(opts) when is_list(opts) do
    auth_path = Keyword.get(opts, :fermix_path, Store.path())
    {sleep, req_options} = Keyword.pop(Keyword.get(opts, :req_options, []), :retry_sleep)
    sleep = sleep || (&Process.sleep/1)

    locked =
      Store.with_profile_lock(Registration.profile(), auth_path, fn ->
        sign_out(auth_path, req_options, sleep)
      end)

    with {:ok, _result} <- locked do
      :ok = TokenSupervisor.forget_signed_out(Registration.profile())
      locked
    end
  end

  # The longest the locked section can take: every revoke attempt at its full
  # request bounds, the sleeps between them, and one store-lock wait. Public so
  # a test can hold it under the profile lock's stale threshold.
  @doc false
  @spec worst_case_ms() :: pos_integer()
  def worst_case_ms do
    store_wait = Store.lock_opts(:store)
    bounds = RefreshClient.request_bounds()

    attempt_ms =
      Keyword.fetch!(bounds, :pool_timeout) +
        Keyword.fetch!(Keyword.fetch!(bounds, :connect_options), :timeout) +
        Keyword.fetch!(bounds, :receive_timeout)

    sleeps_ms = Enum.sum(for attempt <- 1..(@attempts - 1), do: @retry_base_ms * attempt)

    @attempts * attempt_ms + sleeps_ms +
      Keyword.fetch!(store_wait, :attempts) * Keyword.fetch!(store_wait, :delay_ms)
  end

  defp sign_out(auth_path, req_options, sleep) do
    case Registration.read(auth_path) do
      {:ok, nil} -> {:ok, %{revoked: true}}
      {:ok, entry} -> revoke_then_clear(entry, auth_path, req_options, sleep)
      {:error, _reason} = error -> error
    end
  end

  defp revoke_then_clear(entry, auth_path, req_options, sleep) do
    revoked = revoke(entry, req_options, sleep)

    case Store.write(Registration.profile(), Registration.signed_out(entry), auth_path) do
      :ok -> {:ok, %{revoked: revoked}}
      {:error, reason} -> {:error, {:persist_failed, reason}}
    end
  end

  defp revoke(%{client_id: client_id, tokens: %{refresh_token: token}}, req_options, sleep)
       when is_binary(client_id) and is_binary(token) and token != "" do
    form = %{"token" => token, "token_type_hint" => "refresh_token", "client_id" => client_id}
    post(URI.encode_query(form), req_options, sleep, 1)
  end

  defp revoke(%{tokens: %{refresh_token: token}}, _req_options, _sleep)
       when is_binary(token) and token != "" do
    Logger.warning("ChatGPT.Logout: revoke_not_confirmed (no client id to revoke under)")
    false
  end

  # No refresh token: there is no renewable session to revoke.
  defp revoke(_entry, _req_options, _sleep), do: true

  defp post(body, req_options, sleep, attempt) do
    request =
      Req.new(
        [
          url: @revoke_url,
          method: :post,
          body: body,
          headers: [{"content-type", "application/x-www-form-urlencoded"}]
        ] ++ RefreshClient.request_bounds()
      )

    case request |> Req.merge(req_options) |> Egress.attach(:direct) |> Req.request() do
      {:ok, %{status: 200}} ->
        true

      {:ok, %{status: status}} when status >= 500 ->
        retry(body, req_options, sleep, attempt, status)

      {:ok, %{status: status, body: answer}} ->
        not_confirmed("HTTP #{status}", answer)

      {:error, reason} ->
        retry(body, req_options, sleep, attempt, reason)
    end
  end

  defp retry(body, req_options, sleep, attempt, _reason) when attempt < @attempts do
    Logger.warning("ChatGPT.Logout: revoke attempt #{attempt}/#{@attempts} failed; retrying")
    sleep.(@retry_base_ms * attempt)
    post(body, req_options, sleep, attempt + 1)
  end

  defp retry(_body, _req_options, _sleep, _attempt, reason),
    do: not_confirmed("#{@attempts} attempts failed", reason)

  defp not_confirmed(why, detail) do
    Logger.warning(
      "ChatGPT.Logout: revoke_not_confirmed (#{why}: #{Redaction.format(detail)}); " <>
        "clearing local tokens anyway"
    )

    false
  end
end
