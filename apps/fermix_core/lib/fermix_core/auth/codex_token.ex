defmodule FermixCore.Auth.CodexToken do
  @moduledoc """
  Shared Codex OAuth token resolver.

  The daemon keeps tokens warm through `TokenManager`, but CLI setup and
  doctor probes also need a first-class way to read and refresh Codex tokens
  from Fermix-owned auth storage without depending on a running GenServer.
  """

  alias FermixCore.Auth.RefreshClient
  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenExpiry

  @spec get_token(keyword()) :: {:ok, String.t()} | {:error, term()}
  def get_token(opts \\ []) when is_list(opts) do
    path = Keyword.get(opts, :fermix_auth_path, Store.path())
    refresh_opts = Keyword.get(opts, :refresh_req_options, [])

    with {:ok, entry} <- read_entry(path),
         {:ok, entry} <- refresh_if_needed(entry, path, refresh_opts) do
      access_token(entry)
    end
  end

  @spec read_entry(Path.t()) :: {:ok, Store.entry()} | {:error, term()}
  def read_entry(path \\ Store.path())

  def read_entry(path) when is_binary(path) do
    Store.read(:openai_codex, path)
  end

  @account_id_claims ["account_id", "accountId", "sub", "https://api.openai.com/account_id"]

  @doc """
  Extracts the ChatGPT account id from a Codex bearer JWT payload. Shared by the
  Codex chat adapter (`chatgpt-account-id` header) and the Codex image backend so
  the claim-parsing lives in one place. Returns `{:error, reason}` (rather than a
  bare nil) so callers can log why a token yielded no account id.
  """
  @spec account_id_from_token(String.t()) :: {:ok, String.t()} | {:error, term()}
  def account_id_from_token(token) when is_binary(token) do
    with {:ok, payload} <- jwt_payload(token),
         {:ok, decoded} <- decode_payload(payload),
         {:ok, claims} <- decode_claims(decoded) do
      account_id_from_claims(claims)
    end
  end

  def account_id_from_token(_token), do: {:error, :not_a_token}

  defp jwt_payload(token) do
    case String.split(token, ".") do
      [_header, payload | _rest] -> {:ok, payload}
      _parts -> {:error, :missing_payload}
    end
  end

  defp decode_payload(payload) do
    case Base.url_decode64(payload, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_payload_base64}
    end
  end

  defp decode_claims(decoded) do
    case Jason.decode(decoded) do
      {:ok, claims} when is_map(claims) -> {:ok, claims}
      {:ok, _other} -> {:error, :invalid_payload_claims}
      {:error, reason} -> {:error, {:invalid_payload_json, reason}}
    end
  end

  defp account_id_from_claims(claims) do
    case Enum.find_value(@account_id_claims, &nonempty_string(claims[&1])) do
      nil -> {:error, :missing_account_id_claim}
      account_id -> {:ok, account_id}
    end
  end

  @spec refresh_entry(Store.entry(), Path.t(), keyword()) ::
          {:ok, Store.entry()} | {:error, term()}
  def refresh_entry(%{tokens: %{refresh_token: nil}}, path, refresh_opts)
      when is_binary(path) and is_list(refresh_opts) do
    {:error, :no_refresh_token}
  end

  def refresh_entry(%{tokens: %{refresh_token: refresh_token}} = entry, path, refresh_opts)
      when is_binary(refresh_token) and refresh_token != "" and is_binary(path) and
             is_list(refresh_opts) do
    case RefreshClient.refresh(refresh_token, refresh_opts) do
      {:ok, tokens} ->
        refreshed = apply_tokens(entry, tokens)

        case Store.write(:openai_codex, refreshed, path) do
          :ok -> {:ok, refreshed}
          {:error, reason} -> {:error, {:persist_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def refresh_entry(_entry, path, refresh_opts) when is_binary(path) and is_list(refresh_opts),
    do: {:error, :no_refresh_token}

  defp refresh_if_needed(entry, path, refresh_opts) do
    if TokenExpiry.refresh_due?(entry.expires_at) do
      refresh_entry(entry, path, refresh_opts)
    else
      {:ok, entry}
    end
  end

  defp apply_tokens(entry, tokens) do
    %{
      entry
      | tokens: %{
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token || entry.tokens.refresh_token
        },
        expires_at: tokens.expires_at,
        last_refresh: DateTime.utc_now()
    }
  end

  defp access_token(%{tokens: %{access_token: token}}) when is_binary(token) and token != "" do
    {:ok, token}
  end

  defp access_token(_entry), do: {:error, :empty_access_token}

  defp nonempty_string(value) when is_binary(value) and value != "", do: value
  defp nonempty_string(_value), do: nil
end
