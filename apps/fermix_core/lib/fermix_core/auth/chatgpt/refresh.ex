defmodule FermixCore.Auth.ChatGPT.Refresh do
  @moduledoc """
  Refreshes the `chatgpt` token set (M57 §4.3). Both refreshers use it: the
  supervised `TokenManager` and the tree-less `TokenSupervisor.direct_refresh`,
  each under the profile lock it already takes.

  The request is `RefreshClient`'s, with the issued client id read from the
  stored entry (a dynamic client id never lives in code), the `resource`, and
  no `scope`. Nothing is sent before `earliest_refresh_at`: an unexpired token
  is served as it is, an expired one is `:refresh_not_ready`.

  Outcomes:

    * The new set replaces the old one together with its expiry, its
      `earliest_refresh_at` and the granted scopes (a response without `scope`
      keeps the prior grant), once any `id_token` in it names the stored
      subject.
    * `{:reconnect_needed, code}` when the grant can never renew: a terminal
      refresh code, a different account (`:account_mismatch`), or an unreadable
      ID token. The token managers record it as `reauthorization_required`.
    * Anything else (network, 5xx, another 4xx) keeps the stored tokens.
  """

  alias FermixCore.Auth.ChatGPT.IdToken
  alias FermixCore.Auth.ChatGPT.Registration
  alias FermixCore.Auth.OAuthProvider
  alias FermixCore.Auth.Redaction
  alias FermixCore.Auth.RefreshClient
  alias FermixCore.Auth.Store

  require Logger

  @terminal ~w(invalid_grant invalid_refresh_token token_expired refresh_token_expired
               refresh_token_invalidated refresh_token_reused)

  @doc "Refreshes and persists `entry`, or says why not."
  @spec refresh_entry(String.t(), Store.entry(), Path.t(), keyword()) ::
          {:ok, Store.entry()} | {:error, term()}
  def refresh_entry(auth_profile, %{} = entry, path, req_options)
      when is_binary(auth_profile) and is_binary(path) and is_list(req_options) do
    now = DateTime.utc_now()

    cond do
      refresh_allowed?(entry, now) -> refresh_now(auth_profile, entry, path, req_options)
      unexpired?(entry, now) -> {:ok, entry}
      true -> logged({:error, :refresh_not_ready})
    end
  end

  defp refresh_allowed?(%{earliest_refresh_at: %DateTime{} = at}, now),
    do: DateTime.compare(now, at) != :lt

  defp refresh_allowed?(_entry, _now), do: true

  defp unexpired?(%{expires_at: %DateTime{} = at}, now), do: DateTime.compare(at, now) == :gt
  defp unexpired?(_entry, _now), do: false

  defp refresh_now(auth_profile, entry, path, req_options) do
    with {:ok, client_id, refresh_token} <- renewable(entry),
         {:ok, tokens} <- request(client_id, refresh_token, req_options),
         :ok <- same_subject(entry, tokens.id_token),
         {:ok, earliest} <- Registration.earliest_refresh_at(tokens.earliest_refresh_at),
         refreshed = apply_tokens(entry, tokens, earliest),
         :ok <- Store.write(auth_profile, refreshed, path) do
      {:ok, refreshed}
    else
      {:error, _reason} = error -> logged(error)
    end
  end

  # A token set with no client to renew under can never renew.
  defp renewable(%{client_id: client_id, tokens: %{refresh_token: refresh_token}})
       when is_binary(client_id) and is_binary(refresh_token) and refresh_token != "",
       do: {:ok, client_id, refresh_token}

  defp renewable(%{client_id: client_id}) when is_binary(client_id),
    do: {:error, :no_refresh_token}

  defp renewable(_entry), do: {:error, {:reconnect_needed, :missing_client_id}}

  defp request(client_id, refresh_token, req_options) do
    provider = OAuthProvider.chatgpt(client_id: client_id)

    case RefreshClient.refresh(provider, refresh_token, req_options) do
      {:ok, tokens} -> {:ok, tokens}
      {:error, {:permanent, status, body}} -> {:error, refused(status, body)}
      {:error, _reason} = error -> error
    end
  end

  defp refused(_status, %{"error" => code}) when is_binary(code) and code in @terminal,
    do: {:reconnect_needed, code}

  defp refused(status, %{"error" => code}) when is_binary(code),
    do: {:refresh_refused, status, code}

  defp refused(status, _body), do: {:refresh_refused, status, nil}

  defp same_subject(_entry, nil), do: :ok

  defp same_subject(%{subject: subject}, id_token) when is_binary(id_token) do
    case IdToken.subject(id_token) do
      {:ok, ^subject} -> :ok
      {:ok, _other} -> {:error, {:reconnect_needed, :account_mismatch}}
      {:error, :invalid_id_token} -> {:error, {:reconnect_needed, :invalid_id_token}}
    end
  end

  defp apply_tokens(entry, tokens, earliest) do
    %{
      entry
      | tokens: %{
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token || entry.tokens.refresh_token
        },
        expires_at: tokens.expires_at,
        last_refresh: DateTime.utc_now(),
        status: "ready"
    }
    |> Map.put(:earliest_refresh_at, earliest)
    |> Map.put(:granted_scopes, granted(tokens.scope, entry.granted_scopes))
  end

  defp granted(scope, _prior) when is_binary(scope), do: String.split(scope, " ", trim: true)
  defp granted(nil, prior), do: prior

  defp logged({:error, reason} = error) do
    Logger.warning("ChatGPT.Refresh: #{kind(reason)} (#{Redaction.format(reason)})")
    error
  end

  defp kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp kind(reason) when is_tuple(reason) and is_atom(elem(reason, 0)), do: "#{elem(reason, 0)}"
  defp kind(_reason), do: "refresh_failed"
end
