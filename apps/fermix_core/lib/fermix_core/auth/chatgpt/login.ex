defmodule FermixCore.Auth.ChatGPT.Login do
  @moduledoc """
  The Sign in with ChatGPT browser sign-in (M57 §4.2).

  Before the browser opens: the host id exists, and the attempt is built from
  the stored registration. A home with no issued client registers through
  `dynamic_agent_client` with the `Fermix` name hint; one with a client (even a
  pending one) re-authorizes it with no hint, adding `prompt=consent` only when
  its finished grant left plan usage out.

  After the callback, under the `chatgpt` profile lock, in this order:

    1. A newly issued client id is stored as `"pending"` before anything is
       spent, so a failed exchange (`invalid_grant` included) keeps it and the
       next attempt registers no second app.
    2. The code is exchanged with the issued client id, the verifier, the same
       redirect uri and the `resource`.
    3. The ID token is verified, nonce included.
    4. A re-authorization must name the stored subject (`:account_mismatch`
       otherwise, and nothing is replaced).
    5. Plan usage is read from the token response's `scope`, never the
       callback's.
    6. The registration is written.
  """

  alias FermixCore.Auth.ChatGPT.HostId
  alias FermixCore.Auth.ChatGPT.IdToken
  alias FermixCore.Auth.ChatGPT.Registration
  alias FermixCore.Auth.OAuthFlow
  alias FermixCore.Auth.OAuthProvider
  alias FermixCore.Auth.Store

  require Logger

  @flow_opts [:opener, :puts, :timeout_ms]

  @doc "Runs one sign-in attempt in the calling process and stores the result."
  @spec run(keyword()) :: {:ok, Store.entry()} | {:error, term()}
  def run(opts) when is_list(opts) do
    auth_path = Keyword.get(opts, :fermix_path, Store.path())
    req_options = Keyword.get(opts, :req_options, [])

    with {:ok, host_id} <- HostId.fetch_or_create(auth_path),
         {:ok, stored} <- Registration.read(auth_path),
         attempt = attempt(stored, host_id, Keyword.get(opts, :port) || 0),
         {:ok, authorization} <- OAuthFlow.await_authorization(attempt.provider, flow_opts(opts)) do
      redeem(attempt, authorization, auth_path, req_options)
    end
  end

  defp attempt(stored, host_id, port) do
    nonce = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    client_id = stored && stored.client_id

    provider =
      OAuthProvider.chatgpt(
        client_id: client_id,
        host_id: host_id,
        nonce: nonce,
        consent?: Registration.consent_needed?(stored),
        port: port
      )

    %{provider: provider, nonce: nonce, client_id: client_id}
  end

  defp flow_opts(opts) do
    opts
    |> Keyword.take(@flow_opts)
    |> Keyword.put(:paste_message, :chatgpt_callback)
  end

  # Everything that spends or replaces runs under the profile lock: a busy
  # profile refuses before the code is spent.
  defp redeem(attempt, authorization, auth_path, req_options) do
    client_id = authorization.client_id

    Store.with_profile_lock(Registration.profile(), auth_path, fn ->
      with {:ok, current} <- Registration.read(auth_path),
           :ok <- same_registration(current, attempt),
           :ok <- keep_pending(current, client_id, auth_path),
           {:ok, tokens} <- exchange(attempt.provider, client_id, authorization, req_options),
           {:ok, claims} <- verify(tokens, client_id, attempt.nonce, req_options),
           :ok <- same_account(current, claims),
           {:ok, scopes} <- granted_scopes(tokens),
           {:ok, earliest} <- Registration.earliest_refresh_at(tokens.earliest_refresh_at) do
        persist(Registration.signed_in(client_id, claims, tokens, scopes, earliest), auth_path)
      end
    end)
  end

  # The attempt was built from the registration stored when it began. Another
  # sign-in that finished meanwhile is never overwritten by this one.
  defp same_registration(current, %{client_id: client_id}) do
    if (current && current.client_id) == client_id,
      do: :ok,
      else: {:error, :client_mismatch}
  end

  defp keep_pending(%{client_id: client_id}, client_id, _auth_path), do: :ok

  defp keep_pending(_current, client_id, auth_path) do
    case Store.write(Registration.profile(), Registration.pending(client_id), auth_path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:persist_failed, reason}}
    end
  end

  # The code is single-use, so the exchange is one attempt. Its failures are
  # one kind for the person (start again); the vendor's words stay in the
  # detail for the log.
  defp exchange(provider, client_id, authorization, req_options) do
    %{code: code, code_verifier: verifier, redirect_uri: redirect_uri} = authorization

    case OAuthFlow.exchange_code(
           %{provider | client_id: client_id},
           code,
           verifier,
           redirect_uri,
           req_options
         ) do
      {:ok, tokens} -> {:ok, tokens}
      {:error, :invalid_token_response} = error -> error
      {:error, detail} -> {:error, {:token_exchange_failed, detail}}
    end
  end

  defp verify(%{id_token: id_token}, client_id, nonce, req_options) when is_binary(id_token),
    do: IdToken.verify(id_token, client_id, nonce: nonce, req_options: req_options)

  defp verify(_tokens, _client_id, _nonce, _req_options) do
    Logger.warning("ChatGPT.Login: invalid_token_response (no id_token)")
    {:error, :invalid_token_response}
  end

  defp same_account(%{subject: subject}, %{"sub" => sub}) when is_binary(subject) do
    if subject == sub, do: :ok, else: {:error, :account_mismatch}
  end

  defp same_account(_current, _claims), do: :ok

  # The token response's `scope` decides plan usage. A grant with
  # `offline_access` must carry the refresh token it promises.
  defp granted_scopes(%{scope: scope} = tokens) when is_binary(scope) do
    scopes = String.split(scope, " ", trim: true)

    if "offline_access" in scopes and not is_binary(tokens.refresh_token) do
      Logger.warning(
        "ChatGPT.Login: invalid_token_response (offline_access without refresh_token)"
      )

      {:error, :invalid_token_response}
    else
      {:ok, scopes}
    end
  end

  defp granted_scopes(_tokens) do
    Logger.warning("ChatGPT.Login: invalid_token_response (no scope)")
    {:error, :invalid_token_response}
  end

  defp persist(entry, auth_path) do
    case Store.write(Registration.profile(), entry, auth_path) do
      :ok -> {:ok, entry}
      {:error, reason} -> {:error, {:persist_failed, reason}}
    end
  end
end
