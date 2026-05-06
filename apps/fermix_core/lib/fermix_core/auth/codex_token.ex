defmodule FermixCore.Auth.CodexToken do
  @moduledoc """
  Shared Codex OAuth token resolver.

  The daemon keeps tokens warm through `TokenManager`, but CLI setup and
  doctor probes also need a first-class way to read and refresh Codex tokens
  from Fermix-owned auth storage without depending on a running GenServer.
  """

  alias FermixCore.Auth.RefreshClient
  alias FermixCore.Auth.Store

  @refresh_skew_ms 90_000

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
    case refresh_state(entry.expires_at) do
      :fresh -> {:ok, entry}
      :refresh -> refresh_entry(entry, path, refresh_opts)
    end
  end

  defp refresh_state(nil), do: :fresh

  defp refresh_state(expires_at) do
    ms = DateTime.diff(expires_at, DateTime.utc_now(), :millisecond)
    if ms <= @refresh_skew_ms, do: :refresh, else: :fresh
  end

  defp apply_tokens(entry, tokens) do
    %{
      entry
      | tokens: %{
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token || entry.tokens.refresh_token
        },
        expires_at: tokens.expires_at
    }
  end

  defp access_token(%{tokens: %{access_token: token}}) when is_binary(token) and token != "" do
    {:ok, token}
  end

  defp access_token(_entry), do: {:error, :empty_access_token}
end
