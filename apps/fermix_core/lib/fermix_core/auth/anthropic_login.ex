defmodule FermixCore.Auth.AnthropicLogin do
  @moduledoc """
  Anthropic Claude subscription credentials for `auth_mode: :oauth`.

  Two supported inputs (design doc §5.6, in implementation order):

    1. `import_claude_code/1` — one-shot import of an existing Claude Code
       login from its credential store: the macOS keychain service
       `"Claude Code-credentials"` first, then `~/.claude/.credentials.json`.
       Import happens only on explicit user selection — nothing auto-imports
       (Hermes regression: silent seeding flips a session from API-key
       billing to subscription OAuth).
    2. `store_setup_token/2` — persist a long-lived Claude setup token
       (`claude setup-token` output / `CLAUDE_CODE_OAUTH_TOKEN`).

  Native PKCE (manual-paste against the hosted console callback) is
  deferred until the endpoints are verified — §5.6 step 3.

  Entries persist under the `anthropic_oauth` auth profile with
  `provider: "anthropic"` so the TokenSupervisor/TokenManager refresh
  dispatch can key on it. Imports are not refresh-validated here; the
  doctor probe is the validity check.
  """

  alias FermixCore.Auth.Store

  require Logger

  @auth_profile "anthropic_oauth"
  @keychain_service "Claude Code-credentials"
  # Tokens this close to expiry are treated as expired (Hermes parity).
  @expiry_buffer_ms 60_000

  @type opts :: [
          credentials_path: Path.t(),
          keychain_reader: (-> {:ok, String.t()} | :error),
          fermix_path: Path.t()
        ]

  @spec store_setup_token(String.t(), opts()) :: {:ok, Store.entry()} | {:error, term()}
  def store_setup_token(token, opts \\ []) when is_binary(token) and is_list(opts) do
    trimmed = String.trim(token)

    if trimmed == "" do
      raise ArgumentError, "Anthropic setup token must be a non-empty string"
    end

    entry = %{
      auth_mode: "setup_token",
      provider: "anthropic",
      tokens: %{access_token: trimmed, refresh_token: nil},
      expires_at: nil,
      last_refresh: DateTime.utc_now(),
      # Explicit "ready" clears a stale quarantine: Store.put_provider merges
      # over the existing entry and drops nil keys, so an absent status would
      # let an old "reauthorization_required" survive re-login.
      status: "ready"
    }

    persist(entry, Keyword.get(opts, :fermix_path, Store.path()))
  end

  @spec import_claude_code(opts()) :: {:ok, Store.entry()} | {:error, term()}
  def import_claude_code(opts \\ []) when is_list(opts) do
    with {:ok, credentials} <- read_credentials(opts),
         {:ok, entry} <- to_entry(credentials) do
      persist(entry, Keyword.get(opts, :fermix_path, Store.path()))
    end
  end

  @spec claude_code_available?(opts()) :: boolean()
  def claude_code_available?(opts \\ []) when is_list(opts) do
    match?({:ok, _credentials}, read_credentials(opts))
  end

  defp persist(entry, fermix_path) do
    case Store.write(@auth_profile, entry, fermix_path) do
      :ok ->
        Logger.info("AnthropicLogin: persisted #{entry.auth_mode} credentials to #{fermix_path}")
        {:ok, entry}

      {:error, reason} ->
        {:error, {:persist_failed, reason}}
    end
  end

  # Keychain first, then the credentials file — the Claude Code lookup order.
  defp read_credentials(opts) do
    keychain_reader = Keyword.get(opts, :keychain_reader, &default_keychain_read/0)

    case keychain_reader.() do
      {:ok, json} -> parse_credentials(json)
      :error -> read_credentials_file(opts)
    end
  end

  defp read_credentials_file(opts) do
    path = Keyword.get(opts, :credentials_path, default_credentials_path())

    case File.read(path) do
      {:ok, json} -> parse_credentials(json)
      {:error, _reason} -> {:error, :no_claude_code_credentials}
    end
  end

  defp parse_credentials(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"claudeAiOauth" => %{"accessToken" => access} = oauth}}
      when is_binary(access) and access != "" ->
        {:ok, oauth}

      _other ->
        {:error, :claude_code_credentials_invalid}
    end
  end

  defp to_entry(oauth) do
    refresh_token = nonempty(oauth["refreshToken"])
    expires_at = expires_at(oauth["expiresAt"])

    if expired?(expires_at) and is_nil(refresh_token) do
      {:error, :claude_code_credentials_expired}
    else
      {:ok, build_entry(oauth, refresh_token, expires_at)}
    end
  end

  defp build_entry(oauth, refresh_token, expires_at) do
    %{
      auth_mode: "claude_code_import",
      provider: "anthropic",
      tokens: %{access_token: oauth["accessToken"], refresh_token: refresh_token},
      expires_at: expires_at,
      last_refresh: DateTime.utc_now(),
      # See store_setup_token/2 — re-login must clear a stale quarantine.
      status: "ready"
    }
    |> maybe_put_scopes(oauth["scopes"])
  end

  defp maybe_put_scopes(entry, scopes) when is_list(scopes) and scopes != [],
    do: Map.put(entry, :granted_scopes, scopes)

  defp maybe_put_scopes(entry, _scopes), do: entry

  defp expires_at(ms) when is_integer(ms) and ms > 0,
    do: DateTime.from_unix!(ms, :millisecond)

  defp expires_at(_other), do: nil

  defp expired?(nil), do: false

  defp expired?(%DateTime{} = expires_at) do
    DateTime.diff(expires_at, DateTime.utc_now(), :millisecond) <= @expiry_buffer_ms
  end

  defp nonempty(value) when is_binary(value) and value != "", do: value
  defp nonempty(_value), do: nil

  defp default_credentials_path,
    do: Path.join(System.user_home!(), ".claude/.credentials.json")

  defp default_keychain_read do
    with {:darwin, true} <- {:darwin, match?({:unix, :darwin}, :os.type())},
         {output, 0} <-
           System.cmd("security", ["find-generic-password", "-s", @keychain_service, "-w"],
             stderr_to_stdout: true
           ) do
      {:ok, String.trim(output)}
    else
      _miss -> :error
    end
  end
end
