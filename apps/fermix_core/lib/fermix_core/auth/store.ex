defmodule FermixCore.Auth.Store do
  @moduledoc """
  Versioned, provider-scoped auth profile at `~/.fermix/auth.json`.

  Reads tolerate the M3-era flat shape (one provider, top-level keys)
  and normalize it to the new nested shape silently. Writes always
  emit the new shape. Atomic via tmp+rename; perms forced to `0600`.

  Two cross-VM lockfiles (`FermixCore.Plugins.Dist.Lock`) order the writers.
  Every auth profile has its own `TokenManager` process, and CLI VMs, sign-ins
  and logouts write the same file, so no one mailbox serializes them:

    * The store lock (`auth.json.lock`) makes each `write/3` and
      `delete_provider/2` one step: nothing renames the file between its read
      and its own rename, so no writer drops another's update. Reads take no
      lock; the atomic rename keeps every read whole.
    * The profile lock (`with_profile_lock/3`) covers one profile from the read
      of its entry to the write of the result: a refresh, a delete, and a
      sign-in or import from before it spends anything (an authorization-code
      exchange, another tool's refresh token) to its write. Two refreshers never
      present the same refresh token, and a logout or a sign-in never lands
      inside a refresh.

  The profile lock is always taken first, and neither lock is reentrant: a
  locked section never enters another locked entry point or calls a
  `TokenManager`; a reload runs after the release. Every wait is bounded, and
  every profile-lock taker waits the same 10 s: one still busy after it is
  `{:error, :profile_busy}`, returned before the section runs, so a sign-in
  refuses with nothing spent. Any other lock not taken is `{:error, reason}`;
  only a wedged filesystem, timing out the lock owner's calls, exits the caller.

  Each lock's stale threshold exceeds the section it covers, so a live
  holder's lockfile is never broken, barring a wall-clock jump. A refresh is at
  most three attempts and two store-lock waits (about 107 s,
  `RefreshClient.worst_case_ms/0`); a sign-in is at most three single-attempt
  requests (the exchange, the account lookup, a region probe;
  `RefreshClient.request_bounds/0`) and one store-lock wait (about 98 s), and
  the Codex import one refresh and one write. The profile lock's threshold is
  120 s, and `store_test.exs` ("lock bounds") holds these bounds.
  """

  alias FermixCore.Plugins.Dist.Lock

  require Logger

  @schema_version 2

  @type provider :: atom() | String.t()
  @type entry :: %{
          required(:auth_mode) => String.t(),
          required(:tokens) => %{access_token: String.t(), refresh_token: String.t() | nil},
          required(:expires_at) => DateTime.t() | nil,
          required(:last_refresh) => DateTime.t() | nil,
          optional(:provider) => String.t() | nil,
          optional(:account) => map() | nil,
          optional(:scope_profile) => String.t() | nil,
          optional(:granted_scopes) => [String.t()],
          optional(:status) => String.t() | nil,
          optional(:region) => String.t() | nil,
          optional(:region_actual) => String.t() | nil
        }

  @spec read(provider(), Path.t()) :: {:ok, entry()} | {:error, term()}
  def read(provider, path \\ default_path()) when is_atom(provider) or is_binary(provider) do
    with {:ok, raw} <- File.read(path),
         {:ok, data} <- Jason.decode(raw),
         {:ok, providers} <- providers_map(data),
         {:ok, entry} <- fetch_provider(providers, provider) do
      normalize(provider, entry)
    else
      {:error, %Jason.DecodeError{} = err} -> {:error, {:invalid_json, err}}
      {:error, :enoent} -> {:error, :no_auth_file}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Lists every profile in the auth file with its normalized entry. Entries with no
  usable access token are skipped — they are not live credentials, so there is
  nothing to refresh or expiry-check. A missing auth file is the honest empty
  result, not an error.
  """
  @spec list_profiles(Path.t()) :: {:ok, [{String.t(), entry()}]} | {:error, term()}
  def list_profiles(path \\ default_path()) when is_binary(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, data} <- Jason.decode(raw),
         {:ok, providers} <- providers_map(data) do
      {:ok, Enum.flat_map(providers, &normalize_listed/1)}
    else
      {:error, :enoent} -> {:ok, []}
      {:error, %Jason.DecodeError{} = err} -> {:error, {:invalid_json, err}}
      {:error, _reason} = err -> err
    end
  end

  defp normalize_listed({profile, entry}) do
    case normalize(profile, entry) do
      {:ok, normalized} -> [{profile, normalized}]
      {:error, {:invalid_auth_entry, _profile, _reason}} -> []
    end
  end

  # The store lock is held across local I/O of one small file: milliseconds. Its
  # wait outlasts its stale threshold, so a lockfile a dead VM left is broken
  # within one wait and a live writer never fails for want of the lock.
  @store_lock_opts [attempts: 80, delay_ms: 100, stale_after_ms: 5_000]
  # The profile lock is held across one refresh or one sign-in, whose worst
  # cases (see the moduledoc) are under the stale threshold in wall-clock time:
  # a sleep or a clock step mid-section can still make a live holder's lock
  # look stale. Every taker (a refresher, a sign-in, an import, a logout) fails
  # loud after the same 10 s; a VM that died holding the lock blocks the
  # profile 120 s.
  @profile_lock_opts [attempts: 100, delay_ms: 100, stale_after_ms: 120_000]

  @spec write(provider(), entry(), Path.t()) :: :ok | {:error, term()}
  def write(provider, %{} = entry, path \\ default_path())
      when is_atom(provider) or is_binary(provider) do
    lock(store_lock_path(path), @store_lock_opts, :lock_unavailable, fn ->
      merge_write(provider, entry, path)
    end)
  end

  @doc """
  Removes one profile's entry.

  Takes the profile lock, then the store lock, so it waits for a refresh of
  that profile in flight and deletes after it, instead of being undone by that
  refresh's write. A profile lock that stays busy past its wait fails with
  nothing deleted.
  """
  @spec delete_provider(provider(), Path.t()) :: :ok | {:error, term()}
  def delete_provider(provider, path \\ default_path())
      when is_atom(provider) or is_binary(provider) do
    with_profile_lock(provider, path, fn ->
      lock(store_lock_path(path), @store_lock_opts, :lock_unavailable, fn ->
        remove_write(provider, path)
      end)
    end)
  end

  @doc """
  Runs `fun` holding `provider`'s profile lock, across processes and VMs.

  Returns `fun`'s result, `{:error, :profile_busy}` when another holder keeps
  the lock past the wait (a refresh, a sign-in or a logout of the profile in
  another process or VM, or a lockfile a dead VM left), or `{:error, reason}`
  when the lock cannot be taken at all. Either way `fun` has not run. `fun`
  reads the entry itself, under the lock, and must not take the profile lock
  again or call a `TokenManager`.

  A sign-in or an import runs everything it cannot take back inside `fun`: the
  authorization-code exchange or the refresh of another tool's token, then its
  write. A busy profile then refuses before anything is spent, and no refresh
  of the profile can write the old grant's rotation over the new one.
  """
  @spec with_profile_lock(provider(), Path.t(), (-> result)) :: result | {:error, term()}
        when result: term()
  def with_profile_lock(provider, path, fun)
      when (is_atom(provider) or is_binary(provider)) and is_binary(path) and
             is_function(fun, 0) do
    lock(profile_lock_path(provider, path), @profile_lock_opts, :profile_busy, fun)
  end

  @doc """
  The operator's sentence for `{:error, :profile_busy}`. One wording, so every
  surface that signs in, imports or signs out says the same thing.
  """
  @spec busy_sentence() :: String.t()
  def busy_sentence,
    do: "Another Fermix process is refreshing or signing in to this account. Try again shortly."

  # Public so a test can hold the lock bounds to their invariants.
  @doc false
  @spec lock_opts(:store | :profile) :: keyword()
  def lock_opts(:store), do: @store_lock_opts
  def lock_opts(:profile), do: @profile_lock_opts

  @doc false
  @spec store_lock_path(Path.t()) :: Path.t()
  def store_lock_path(path) when is_binary(path), do: path <> ".lock"

  # A profile name is operator-settable config (`Plugins.Config.auth_profile/1`),
  # so it is encoded: no `/` or `..` in it can move the lockfile out of the
  # auth file's directory. The name starts with the auth file's own, so two
  # auth files in one directory never share a profile's lock.
  @doc false
  @spec profile_lock_path(provider(), Path.t()) :: Path.t()
  def profile_lock_path(provider, path)
      when (is_atom(provider) or is_binary(provider)) and is_binary(path),
      do: "#{path}.#{Base.url_encode64(provider_key(provider), padding: false)}.lock"

  @spec path() :: Path.t()
  def path, do: default_path()

  # The one provider -> auth-profile table. A profile name is not the provider
  # id: anthropic and xai store their OAuth entries under their own profile,
  # so reading `auth.json` under the provider id finds nothing and reports a
  # signed-in account as absent.
  @auth_profiles %{openai_codex: "openai_codex", anthropic: "anthropic_oauth", xai: "xai_oauth"}

  @doc """
  The auth profile a provider's credentials live under, or `nil` for a provider
  that has no OAuth profile at all.
  """
  @spec profile(atom()) :: String.t() | nil
  def profile(provider) when is_atom(provider), do: Map.get(@auth_profiles, provider)

  @doc "Every provider that stores credentials under an auth profile, ordered."
  @spec profiled_providers() :: [atom()]
  def profiled_providers, do: @auth_profiles |> Map.keys() |> Enum.sort()

  @doc """
  The operator-facing account name on an entry, or `nil` when the provider gave
  none. One reader, so two surfaces cannot label the same account differently.
  """
  @spec account_label(entry()) :: String.t() | nil
  def account_label(%{} = entry) do
    case Map.get(entry, :account) do
      %{} = account -> label_value(Map.get(account, :email) || Map.get(account, :label))
      _absent -> nil
    end
  end

  defp label_value(value) when is_binary(value) and value != "", do: value
  defp label_value(_value), do: nil

  # The statuses a sign-in writes onto a grant that must not be served, and the
  # reason each answers with. `reauthorization_required` and `client_rejected`
  # are NOT here: a refresh writes those, and the refresher that wrote one is
  # already refusing in memory, so reading them back would change how an
  # unexpired grant behaves across a restart. `wrong_region` is the one a LOGIN
  # writes, so the entry is the only place it can be read from.
  @quarantines %{"wrong_region" => :wrong_region}

  @doc """
  Why a stored grant must not be served, or `nil` when it may be.

  One reader, so the supervised token manager and the tree-less direct read
  answer a quarantined grant identically: a CLI VM with no manager must not hand
  out the credential the daemon refuses.
  """
  @spec quarantine_reason(entry()) :: atom() | nil
  def quarantine_reason(%{} = entry), do: Map.get(@quarantines, Map.get(entry, :status))

  @spec validate_permissions(Path.t()) ::
          :ok | {:error, {:insecure_permissions, Path.t(), non_neg_integer()}} | {:error, term()}
  def validate_permissions(path \\ default_path()) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} ->
        check_mode(path, Bitwise.band(mode, 0o777))

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec validate_permissions!(Path.t()) :: :ok
  def validate_permissions!(path \\ default_path()) when is_binary(path) do
    case validate_permissions(path) do
      :ok ->
        :ok

      {:error, {:insecure_permissions, ^path, mode}} ->
        raise ArgumentError, permissions_message(path, mode)

      {:error, reason} ->
        raise ArgumentError, "failed to stat #{path}: #{inspect(reason)}"
    end
  end

  @spec permissions_message(Path.t(), non_neg_integer()) :: String.t()
  def permissions_message(path, mode) when is_binary(path) and is_integer(mode) do
    "#{path} has perms 0o#{Integer.to_string(mode, 8)} (expected 0o600). " <>
      "Run `chmod 600 #{path}` and restart."
  end

  defp default_path do
    home = System.get_env("FERMIX_HOME") || Path.join(System.user_home!(), ".fermix")
    Path.join(home, "auth.json")
  end

  defp check_mode(_path, 0o600), do: :ok
  defp check_mode(path, mode), do: {:error, {:insecure_permissions, path, mode}}

  defp providers_map(%{"providers" => providers}) when is_map(providers), do: {:ok, providers}

  # Migration: M3-era flat shape — one ChatGPT OAuth provider implicit at
  # the top level. It belongs to openai_codex, not api-key openai.
  defp providers_map(%{"tokens" => _} = flat),
    do: {:ok, %{"openai_codex" => flat}}

  defp providers_map(_), do: {:error, :no_providers}

  defp fetch_provider(providers, provider) do
    case Map.get(providers, provider_key(provider)) do
      nil -> {:error, {:provider_missing, provider}}
      entry -> {:ok, entry}
    end
  end

  defp normalize(provider, entry) do
    tokens = Map.get(entry, "tokens", %{})
    access = Map.get(tokens, "access_token")

    if is_binary(access) and access != "" do
      {:ok, normalized_entry(entry, tokens, access)}
    else
      {:error, {:invalid_auth_entry, provider, :missing_access_token}}
    end
  end

  defp normalized_entry(entry, tokens, access) do
    %{
      auth_mode: Map.get(entry, "auth_mode") || "chatgpt",
      provider: Map.get(entry, "provider"),
      account: normalize_account(Map.get(entry, "account")),
      scope_profile: Map.get(entry, "scope_profile"),
      granted_scopes: normalize_string_list(Map.get(entry, "granted_scopes")),
      tokens: %{
        access_token: access,
        refresh_token: Map.get(tokens, "refresh_token")
      },
      expires_at: parse_iso8601(Map.get(entry, "expires_at")),
      last_refresh: parse_iso8601(Map.get(entry, "last_refresh")),
      status: Map.get(entry, "status"),
      # The provider region the grant was minted for (Tesla's Fleet API region),
      # recorded at sign-in because nothing downstream can re-derive it. `nil`
      # for every provider that has no regions.
      region: Map.get(entry, "region"),
      # The region the account itself is in, recorded beside `region` when the
      # sign-in found the two disagree. Only ever meaningful beside a
      # `wrong_region` status; `nil` says nothing was found to disagree with.
      region_actual: Map.get(entry, "region_actual")
    }
  end

  defp normalize_account(account) when is_map(account) do
    account
    |> Enum.into(%{}, fn {key, value} -> {normalize_account_key(key), value} end)
    |> atomize_known_account_keys()
  end

  defp normalize_account(_account), do: nil

  defp normalize_account_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_account_key(key) when is_binary(key), do: key

  defp atomize_known_account_keys(account) do
    account
    |> maybe_atomize_key("subject", :subject)
    |> maybe_atomize_key("email", :email)
    |> maybe_atomize_key("display_name", :display_name)
  end

  defp maybe_atomize_key(account, string_key, atom_key) do
    case Map.fetch(account, string_key) do
      {:ok, value} -> account |> Map.delete(string_key) |> Map.put(atom_key, value)
      :error -> account
    end
  end

  defp normalize_string_list(values) when is_list(values) do
    Enum.filter(values, &is_binary/1)
  end

  defp normalize_string_list(_values), do: []

  defp parse_iso8601(nil), do: nil

  defp parse_iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp merge_write(provider, entry, path) do
    with {:ok, current} <- read_for_write(path),
         updated <- put_provider(current, provider, entry),
         :ok <- atomic_write(path, encode(updated)) do
      :ok
    end
  end

  defp remove_write(provider, path) do
    with {:ok, current} <- read_existing(path),
         {:ok, updated} <- remove_provider(current, provider),
         :ok <- atomic_write(path, encode(updated)) do
      :ok
    end
  end

  defp read_for_write(path) do
    case File.read(path) do
      {:ok, raw} ->
        decode_for_write(path, raw)

      {:error, :enoent} ->
        {:ok, empty_doc()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_for_write(path, raw) do
    case Jason.decode(raw) do
      {:ok, %{"providers" => providers} = data} when is_map(providers) ->
        {:ok, data}

      {:ok, %{"tokens" => _} = flat} ->
        {:ok, legacy_codex_doc(flat)}

      {:ok, _other} ->
        preserve_and_refuse(path, raw, :unknown_shape)

      {:error, %Jason.DecodeError{} = err} ->
        preserve_and_refuse(path, raw, {:invalid_json, err})
    end
  end

  defp preserve_and_refuse(path, raw, reason) do
    backup = "#{path}.broken.#{System.system_time(:second)}"

    case File.write(backup, raw, [:binary]) do
      :ok ->
        _ = File.chmod(backup, 0o600)

        Logger.error(
          "Auth.Store: refusing to overwrite #{path} (#{inspect(reason)}); preserved at #{backup}"
        )

        {:error, {:malformed_auth_file, path, backup, reason}}

      {:error, write_err} ->
        Logger.error(
          "Auth.Store: refusing to overwrite #{path} (#{inspect(reason)}); backup also failed: #{inspect(write_err)}"
        )

        {:error, {:malformed_auth_file, path, nil, reason}}
    end
  end

  defp read_existing(path) do
    case File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{"providers" => providers} = data} when is_map(providers) -> {:ok, data}
          {:ok, %{"tokens" => _} = flat} -> {:ok, legacy_codex_doc(flat)}
          {:ok, _} -> {:error, :no_providers}
          {:error, %Jason.DecodeError{} = err} -> {:error, {:invalid_json, err}}
        end

      {:error, :enoent} ->
        {:error, :no_auth_file}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp empty_doc, do: %{"version" => @schema_version, "providers" => %{}}

  defp legacy_codex_doc(flat),
    do: %{"version" => @schema_version, "providers" => %{"openai_codex" => flat}}

  defp put_provider(doc, provider, entry) do
    providers = Map.get(doc, "providers", %{})
    provider_key = provider_key(provider)
    existing = Map.get(providers, provider_key, %{})

    serialized =
      %{
        "auth_mode" => entry_value(entry, :auth_mode, "chatgpt"),
        "tokens" => %{
          "access_token" => entry.tokens.access_token,
          "refresh_token" => entry.tokens.refresh_token
        },
        "expires_at" => encode_datetime(entry_value(entry, :expires_at)),
        "last_refresh" => DateTime.to_iso8601(DateTime.utc_now())
      }
      |> put_serialized("provider", entry_value(entry, :provider))
      |> put_serialized("account", stringify_account(entry_value(entry, :account)))
      |> put_serialized("scope_profile", entry_value(entry, :scope_profile))
      |> put_serialized("granted_scopes", entry_value(entry, :granted_scopes, []))
      |> put_serialized("status", entry_value(entry, :status))
      |> put_serialized("region", entry_value(entry, :region))
      |> put_serialized("region_actual", entry_value(entry, :region_actual))

    providers = Map.put(providers, provider_key, Map.merge(existing, serialized))
    %{"version" => @schema_version, "providers" => providers}
  end

  defp remove_provider(%{"providers" => providers}, provider) when is_map(providers) do
    key = provider_key(provider)

    if Map.has_key?(providers, key) do
      {:ok, %{"version" => @schema_version, "providers" => Map.delete(providers, key)}}
    else
      {:error, {:provider_missing, provider}}
    end
  end

  defp remove_provider(_doc, _provider), do: {:error, :no_providers}

  defp provider_key(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp provider_key(provider) when is_binary(provider), do: provider

  defp entry_value(entry, key, default \\ nil) when is_map(entry) do
    Map.get(entry, key, Map.get(entry, Atom.to_string(key), default))
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp stringify_account(nil), do: nil

  defp stringify_account(account) when is_map(account) do
    Enum.into(account, %{}, fn {key, value} -> {account_key(key), value} end)
  end

  defp account_key(key) when is_atom(key), do: Atom.to_string(key)
  defp account_key(key) when is_binary(key), do: key

  defp put_serialized(map, _key, nil), do: map
  defp put_serialized(map, _key, []), do: map
  defp put_serialized(map, key, value), do: Map.put(map, key, value)

  defp encode(doc), do: Jason.encode!(doc, pretty: true) <> "\n"

  # `Lock.with_lock/3` raises when it cannot create the lock's directory, and
  # its owner is linked to the caller. A raise inside the Codex TokenManager
  # restarts every later child of the top-level `:rest_for_one` tree, so the
  # directory is made here first and a lock not taken is a tuple. Only a wedged
  # filesystem, timing out the owner's own calls, still exits the caller.
  # `busy` is the answer when another holder keeps the lock past the wait.
  defp lock(lock_path, opts, busy, fun) do
    case File.mkdir_p(Path.dirname(lock_path)) do
      :ok -> hold(lock_path, opts, busy, fun)
      {:error, reason} -> lock_failed(lock_path, reason)
    end
  end

  # `fun`'s result is wrapped, so an error it returns is never taken for the
  # lock's own.
  defp hold(lock_path, opts, busy, fun) do
    case Lock.with_lock(lock_path, fn -> {:locked, fun.()} end, opts) do
      {:locked, result} -> result
      {:error, :lock_unavailable} -> lock_failed(lock_path, busy)
      {:error, reason} -> lock_failed(lock_path, reason)
    end
  end

  defp lock_failed(lock_path, reason) do
    Logger.warning("Auth.Store: could not take #{lock_path}: #{inspect(reason)}")
    {:error, reason}
  end

  defp atomic_write(path, contents) do
    dir = Path.dirname(path)
    tmp = "#{path}.tmp.#{System.unique_integer([:positive, :monotonic])}"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, contents, [:binary]),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        Logger.warning("Auth.Store: failed to persist — #{inspect(reason)}")
        {:error, reason}
    end
  end
end
