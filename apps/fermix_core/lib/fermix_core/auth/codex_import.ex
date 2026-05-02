defmodule FermixCore.Auth.CodexImport do
  @moduledoc """
  One-shot import of OpenAI tokens from a Codex CLI install.

  Performs a single OAuth refresh against the Codex refresh token, then
  persists the refreshed tokens to `~/.fermix/auth.json` via
  `FermixCore.Auth.Store` under the `openai_codex` provider scope. The
  Codex file is never read again after this — the refresh attempt is the
  sole authoritative validity test per the M4.8 design.

  Refusing to ship a degraded path: if the refresh fails, this returns
  the failure reason. Callers (the wizard) re-prompt with the remaining
  options instead of falling back to a stale token.
  """

  alias FermixCore.Auth.RefreshClient
  alias FermixCore.Auth.Store

  require Logger

  @type opts :: [
          codex_path: Path.t(),
          fermix_path: Path.t(),
          req_options: keyword()
        ]

  @spec import_tokens(opts()) :: {:ok, Store.entry()} | {:error, term()}
  def import_tokens(opts \\ []) do
    codex_path = Keyword.get(opts, :codex_path, default_codex_path())
    fermix_path = Keyword.get(opts, :fermix_path, Store.path())
    req_options = Keyword.get(opts, :req_options, [])

    with {:ok, codex} <- read_codex(codex_path),
         {:ok, refreshed} <- RefreshClient.refresh(codex.refresh_token, req_options),
         entry <- to_entry(refreshed),
         :ok <- Store.write(:openai_codex, entry, fermix_path) do
      Logger.info("CodexImport: imported and persisted refreshed tokens to #{fermix_path}")
      {:ok, entry}
    end
  end

  @spec codex_available?(Path.t()) :: boolean()
  def codex_available?(path \\ default_codex_path()) do
    case read_codex(path) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp read_codex(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, data} <- Jason.decode(raw),
         %{"tokens" => %{"refresh_token" => rt}} when is_binary(rt) and rt != "" <- data do
      {:ok, %{refresh_token: rt}}
    else
      {:error, :enoent} -> {:error, :no_codex_auth}
      {:error, %Jason.DecodeError{}} -> {:error, :codex_auth_invalid_json}
      _ -> {:error, :codex_auth_missing_refresh_token}
    end
  end

  defp to_entry(%{access_token: access, refresh_token: refresh, expires_at: expires_at}) do
    %{
      auth_mode: "chatgpt",
      tokens: %{access_token: access, refresh_token: refresh},
      expires_at: expires_at,
      last_refresh: DateTime.utc_now()
    }
  end

  defp default_codex_path, do: Path.join(System.user_home!(), ".codex/auth.json")
end
