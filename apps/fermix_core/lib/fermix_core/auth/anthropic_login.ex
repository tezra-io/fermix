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
  alias FermixCore.CommandRunner
  alias FermixCore.Management.Jobs
  alias FermixCore.Setup.SecretWriter.MacOS

  require Logger

  @auth_profile Store.profile(:anthropic)
  @keychain_service "Claude Code-credentials"
  # `-g` prints the item's attributes and one `password: ` line that says which
  # form it printed, and `SecretWriter.MacOS.get_result/1` reads it byte for
  # byte. `-w` prints a value holding any byte outside space to tilde as bare
  # hex, which no reader can tell from a value made of hex digits.
  @keychain_read ["find-generic-password", "-s", @keychain_service, "-g"]
  # errSecItemNotFound: the keychain holds no Claude Code login.
  @item_not_found_exit 44
  # errSecAuthFailed (-25293) and errSecUserCanceled (-128), cut to their low
  # byte: the allow prompt was denied, or cancelled.
  @denied_exits [51, 128]
  # errSecInteractionNotAllowed (-25308): there is no screen to show the
  # prompt on, as over SSH.
  @prompt_unavailable_exit 36
  @login_failures [
    :no_claude_code_credentials,
    :claude_code_credentials_invalid,
    :claude_code_credentials_expired
  ]
  @keychain_failures [
    :keychain_read_denied,
    :keychain_read_timeout,
    :keychain_prompt_unavailable,
    :unreadable_keychain_password,
    :helper_output_too_large,
    :missing_secret
  ]
  # The presence probe's own bound. It is a metadata lookup, not a network call
  # and not a value read, so a second of wall clock is already generous.
  @presence_timeout_ms 2_000
  # Tokens this close to expiry are treated as expired (Hermes parity).
  @expiry_buffer_ms 60_000

  @type keychain_answer :: {:ok, String.t()} | :error | {:error, term()}
  @typedoc """
  A failed import `failure_sentence/1` words, inside the import's own tag: the
  keychain read's reasons are spelled like SecretWriter's, and only the tag
  says one is Claude Code's. None holds a helper's output.
  """
  @type import_failure :: {:claude_code_import, import_reason()}
  @type import_reason ::
          :no_claude_code_credentials
          | :claude_code_credentials_invalid
          | :claude_code_credentials_expired
          | :keychain_read_denied
          | :keychain_read_timeout
          | :keychain_prompt_unavailable
          | :unreadable_keychain_password
          | :helper_output_too_large
          | :missing_secret
          | {:keychain_read_failed, integer()}
  @type opts :: [
          credentials_path: Path.t(),
          keychain_reader: (-> keychain_answer()),
          keychain_present?: (-> boolean()),
          security_path: Path.t() | nil,
          command_runner: (String.t(), [String.t()], keyword() ->
                             {:ok, CommandRunner.result()} | {:error, term()}),
          supervised: boolean(),
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

  @doc """
  Imports Claude Code's login. A failure to read or use it is
  `{:claude_code_import, reason}`; one in persisting it (`:profile_busy`,
  `{:persist_failed, reason}`) is the store's, untagged.
  """
  @spec import_claude_code(opts()) ::
          {:ok, Store.entry()} | {:error, {:claude_code_import, term()} | term()}
  def import_claude_code(opts \\ []) when is_list(opts) do
    with {:ok, credentials} <- read_credentials(opts),
         {:ok, entry} <- to_entry(credentials) do
      persist(entry, Keyword.get(opts, :fermix_path, Store.path()))
    else
      {:error, reason} -> {:error, {:claude_code_import, reason}}
    end
  end

  @doc "Whether `reason` is an import failure `failure_sentence/1` words."
  defguard is_import_failure(reason)
           when is_tuple(reason) and tuple_size(reason) == 2 and
                  elem(reason, 0) == :claude_code_import and
                  (elem(reason, 1) in @login_failures or elem(reason, 1) in @keychain_failures or
                     (is_tuple(elem(reason, 1)) and tuple_size(elem(reason, 1)) == 2 and
                        elem(elem(reason, 1), 0) == :keychain_read_failed and
                        is_integer(elem(elem(reason, 1), 1))))

  @doc "Every failure `failure_sentence/1` words, one exit status standing for all."
  @spec worded_failures() :: [import_failure()]
  def worded_failures do
    Enum.map(
      @login_failures ++ @keychain_failures ++ [{:keychain_read_failed, 1}],
      &{:claude_code_import, &1}
    )
  end

  @doc """
  The sentence a person reads when an import failed, the same on every surface
  that imports (the Mac app, the browser setup, `fermix auth login`). It names
  the reason and never quotes the keychain tool, whose output can hold the
  secret. A failure it does not word (a busy profile, a failed write, a runner
  that could not start) is the caller's to word and log.
  """
  @spec failure_sentence(import_failure()) :: String.t()
  def failure_sentence({:claude_code_import, reason} = failure) when is_import_failure(failure),
    do: sentence(reason)

  @doc """
  Whether a Claude Code login exists on this machine, without reading it.

  Reading the credential means `security ... -g` on macOS: that returns the
  token itself and raises the keychain allow dialog, so a daemon asking it
  blocks until a human answers a modal about another app's secret. A detection
  row or a page deciding whether to offer the import needs presence, not the
  value, so this asks the keychain whether the item exists (no `-g`, exit code
  only) under an explicit timeout, and otherwise whether the credentials file
  is there — the same two stores, in the same order, that `read_credentials/1`
  consults.
  """
  @spec claude_code_present?(opts()) :: boolean()
  def claude_code_present?(opts \\ []) when is_list(opts) do
    present? = Keyword.get(opts, :keychain_present?, fn -> keychain_item_present?(opts) end)

    present?.() or File.exists?(credentials_path(opts))
  end

  # Nothing is spent before the write, so the write alone takes the profile
  # lock: it cannot land inside a refresh of the profile and be overwritten by
  # it, and a profile busy past the lock's wait refuses with the typed reason.
  defp persist(entry, fermix_path) do
    locked =
      Store.with_profile_lock(@auth_profile, fermix_path, fn ->
        Store.write(@auth_profile, entry, fermix_path)
      end)

    case locked do
      :ok ->
        Logger.info("AnthropicLogin: persisted #{entry.auth_mode} credentials to #{fermix_path}")
        {:ok, entry}

      {:error, :profile_busy} ->
        {:error, :profile_busy}

      {:error, reason} ->
        {:error, {:persist_failed, reason}}
    end
  end

  # Keychain first, then the credentials file — the Claude Code lookup order.
  # The file answers only when the keychain holds no login; a keychain read
  # that failed is reported, never answered from the other store.
  defp read_credentials(opts) do
    keychain_reader = Keyword.get(opts, :keychain_reader, fn -> read_keychain(opts) end)

    case keychain_reader.() do
      {:ok, json} -> parse_credentials(json)
      :error -> read_credentials_file(opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_credentials_file(opts) do
    path = credentials_path(opts)

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

  defp credentials_path(opts),
    do: Keyword.get(opts, :credentials_path, default_credentials_path())

  defp default_credentials_path,
    do: Path.join(System.user_home!(), ".claude/.credentials.json")

  # `find-generic-password` WITHOUT `-w` prints the item's attributes and exits
  # 0; it never returns the secret and never consults the item's ACL, so it
  # cannot prompt. Exit 44 is "item not found"; every other non-zero exit and
  # every runner error is reported as absent, because this row only claims a
  # login it can see.
  #
  # There is no platform branch: `security` is the macOS keychain tool and a
  # host without one resolves no executable, which is the same answer a branch
  # would have given. One code path, and it is the one the test drives.
  defp keychain_item_present?(opts) do
    with security when is_binary(security) <- security_path(opts),
         {:ok, %{exit: 0}} <-
           CommandRunner.run(security, ["find-generic-password", "-s", @keychain_service],
             timeout_ms: @presence_timeout_ms
           ) do
      true
    else
      _absent -> false
    end
  end

  defp security_path(opts) do
    case Keyword.fetch(opts, :security_path) do
      {:ok, path} -> path
      :error -> System.find_executable("security")
    end
  end

  # The item the presence probe asks about, read through the parser Fermix
  # reads its own keychain items with, and on the same terms as that probe: no
  # platform branch, the absolute `security`. Only an import reads it, which a
  # person starts, and reading another app's item can raise the allow prompt,
  # so the read waits for their answer: half the Mac app's import job budget
  # (`Management.Jobs`), which leaves the job the other half to verify the
  # login. The caller says whether a command host exists to run it (the
  # tree-less CLI does not).
  defp read_keychain(opts) do
    case security_path(opts) do
      nil ->
        :error

      security ->
        run_opts =
          [timeout_ms: div(Jobs.budget_ms(:auth_import), 2)] ++
            Keyword.take(opts, [:supervised])

        keychain_answer(command_runner(opts).(security, @keychain_read, run_opts))
    end
  end

  defp keychain_answer({:ok, %{exit: 0, stdout: output, truncated?: false}}),
    do: MacOS.get_result({:ok, output})

  # What was read is the start of the answer, which can be the secret.
  defp keychain_answer({:ok, %{truncated?: true}}), do: {:error, :helper_output_too_large}

  defp keychain_answer({:ok, %{exit: @item_not_found_exit}}), do: :error

  defp keychain_answer({:ok, %{exit: code}}) when code in @denied_exits,
    do: {:error, :keychain_read_denied}

  defp keychain_answer({:ok, %{exit: @prompt_unavailable_exit}}),
    do: {:error, :keychain_prompt_unavailable}

  # The status alone: what the tool printed beside it can hold the secret.
  defp keychain_answer({:ok, %{exit: code}}), do: {:error, {:keychain_read_failed, code}}

  defp keychain_answer({:error, {:timeout, _timeout_ms}}), do: {:error, :keychain_read_timeout}

  defp keychain_answer({:error, reason}), do: {:error, {:keychain_runner_failed, reason}}

  defp sentence(:no_claude_code_credentials),
    do: "No Claude Code sign-in was found on this computer. Sign in to Claude Code, then import."

  defp sentence(:claude_code_credentials_invalid),
    do: "Claude Code's sign-in on this computer could not be read, so there was nothing to adopt."

  defp sentence(:claude_code_credentials_expired) do
    "Claude Code's sign-in on this computer has expired, so there was nothing to adopt. " <>
      "Sign in to Claude Code again, then import."
  end

  defp sentence(:keychain_read_denied) do
    "macOS did not let Fermix read Claude Code's sign-in from the login keychain. " <>
      "Import again and allow access when macOS asks."
  end

  defp sentence(:keychain_read_timeout) do
    "No one answered the login keychain prompt in time, so Claude Code's sign-in was " <>
      "not read. Import again and answer the prompt."
  end

  defp sentence(:keychain_prompt_unavailable) do
    "macOS can't show the login keychain prompt here (no screen session), so Claude " <>
      "Code's sign-in was not read. Run the import from the Mac's own desktop."
  end

  defp sentence(:unreadable_keychain_password) do
    "The login keychain answered in a form Fermix does not read, so Claude Code's sign-in " <>
      "was not used."
  end

  defp sentence(:helper_output_too_large) do
    "The login keychain answered with more than Fermix reads, so none of Claude Code's " <>
      "sign-in was used."
  end

  defp sentence(:missing_secret),
    do: "Claude Code's login keychain item is empty, so there was nothing to adopt."

  defp sentence({:keychain_read_failed, code}) do
    "The login keychain did not hand over Claude Code's sign-in (the keychain tool " <>
      "exited #{code})."
  end

  defp command_runner(opts) do
    case Keyword.get(opts, :command_runner, &CommandRunner.run/3) do
      runner when is_function(runner, 3) ->
        runner

      other ->
        raise ArgumentError,
              ":command_runner must be a function of arity 3, got: #{inspect(other)}"
    end
  end
end
