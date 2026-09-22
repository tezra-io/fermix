defmodule FermixCore.Setup.SecretStore do
  @moduledoc """
  Snapshot helpers for setup-managed secrets.

  `SecretPaths` is the registry. Any value at a registered path is stored
  through `SecretWriter` before the snapshot is written to disk, in the store
  the snapshot's `[fermix_core] secret_store` names, and is persisted as that
  store's sentinel. At boot each sentinel is resolved from the store it names,
  so a home whose secrets are split between the keyring and the file store
  reads every one of them from where it is.

  Both directions probe a store before using it (`SecretWriter.probe/1`): a
  save that cannot store a new secret says why instead of hanging on an
  unlock dialog, and a boot on a locked keyring leaves those sentinels in
  place with one line in the log rather than raising that dialog from the
  daemon, once per secret.
  """

  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.SecretPaths
  alias FermixCore.Setup.SecretWriteLog
  alias FermixCore.Setup.SecretWriter

  require Logger

  @type snapshot :: map()
  @type path :: [atom() | String.t()]

  @spec secure_snapshot(snapshot(), keyword()) :: {:ok, snapshot()} | {:error, String.t()}
  def secure_snapshot(snapshot, opts \\ []) when is_map(snapshot) and is_list(opts) do
    previous = Keyword.get(opts, :previous)

    write_opts =
      [profile: profile_of(snapshot), store: store_of(snapshot)] ++
        Keyword.take(opts, [:supervised])

    verdicts = probe_stores_this_save_touches(snapshot, previous, write_opts)

    Enum.reduce_while(SecretPaths.all(), {:ok, snapshot}, fn secret, {:ok, acc} ->
      case secure_secret(acc, previous, secret, write_opts, verdicts) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # One verdict per store this save may read or write, taken before any of it
  # happens: the configured store whenever a plaintext value would be written
  # to it, and the store a persisted sentinel names whenever that secret's
  # value has to be compared against what is stored. A save that carries no
  # plaintext asks nothing of any store.
  defp probe_stores_this_save_touches(snapshot, previous, write_opts) do
    stores =
      Enum.flat_map(SecretPaths.all(), fn secret ->
        value = get_snapshot_value(snapshot, secret.path)
        old_value = previous_value(previous, secret.path)

        case {plaintext_secret?(value), SecretWriter.store_of_sentinel(old_value)} do
          {false, _} -> []
          {true, {:ok, old_store}} -> [old_store, write_opts[:store]]
          {true, :error} -> [write_opts[:store]]
        end
      end)

    Map.new(Enum.uniq(stores), fn store ->
      {store, SecretWriter.probe(Keyword.put(write_opts, :store, store))}
    end)
  end

  # Each keyring read shells out one `security`/`secret-tool` subprocess
  # (~40 ms healthy, 3 s timeout degraded); a config with 15 sentinels paid
  # ~0.5 s sequentially at every boot — minutes when the keychain hangs.
  @keyring_read_concurrency 8
  # SecretWriter bounds each read at 3 s + kill grace; this only backstops
  # a stuck task. Hitting it means the read failed: the sentinel stays.
  @keyring_read_timeout_ms 10_000

  # `supervised` is owned by the caller's world: the boot config-provider chain
  # (`ConfigStore.bootstrap_runtime_config`) passes `supervised: false` since no
  # supervision tree exists yet; daemon callers omit it and `SecretWriter`/
  # `CommandRunner` default to the supervised host. Never probed at runtime.
  @spec resolve_sentinels(snapshot(), keyword()) :: snapshot()
  def resolve_sentinels(snapshot, opts) when is_map(snapshot) and is_list(opts) do
    warn_plaintext? = Keyword.fetch!(opts, :warn_plaintext)
    profile = profile_of(snapshot)
    read_opts = [profile: profile] ++ Keyword.take(opts, [:supervised])

    by_store =
      Enum.group_by(SecretPaths.all(), fn secret ->
        case SecretWriter.store_of_sentinel(get_snapshot_value(snapshot, secret.path)) do
          {:ok, store} -> store
          :error -> :plain
        end
      end)

    if warn_plaintext? do
      by_store
      |> Map.get(:plain, [])
      |> Enum.filter(&plaintext_secret?(get_snapshot_value(snapshot, &1.path)))
      |> Enum.each(&warn_plaintext_secret/1)
    end

    snapshot
    |> resolve_store(:keyring, Map.get(by_store, :keyring, []), warn_plaintext?, read_opts)
    |> resolve_store(:file, Map.get(by_store, :file, []), warn_plaintext?, read_opts)
  end

  # A store is asked whether it can answer before any secret is asked of it:
  # on a locked keyring the sentinels stay, the log says why once, and no
  # `secret-tool` runs — which is what keeps the desktop's unlock dialog from
  # being raised by a daemon nobody is looking at.
  defp resolve_store(snapshot, _store, [], _warn?, _read_opts), do: snapshot

  defp resolve_store(snapshot, store, secrets, warn?, read_opts) do
    store_opts = Keyword.put(read_opts, :store, store)
    verdict = SecretWriter.probe(store_opts)

    if SecretWriter.usable?(verdict) do
      resolve_from_store(snapshot, secrets, warn?, store_opts)
    else
      if warn?, do: warn_unusable_store(verdict, secrets)
      snapshot
    end
  end

  # Reads are independent, so fan out over a bounded task pool and merge
  # deterministically (ordered stream zipped back to its input). Failure
  # semantics stay in handle_keyring_resolution_error: warn, keep sentinel.
  defp resolve_from_store(snapshot, secrets, warn?, read_opts) do
    secrets
    |> Task.async_stream(
      fn secret -> SecretWriter.get(secret.key, read_opts) end,
      max_concurrency: @keyring_read_concurrency,
      timeout: @keyring_read_timeout_ms,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(secrets)
    |> Enum.reduce(snapshot, fn
      {{:ok, {:ok, value}}, secret}, acc ->
        put_snapshot_value(acc, secret.path, value)

      {{:ok, {:error, reason}}, secret}, acc ->
        handle_keyring_resolution_error(acc, secret, reason, warn?)

      {{:exit, reason}, secret}, acc ->
        handle_keyring_resolution_error(acc, secret, {:task_exit, reason}, warn?)
    end)
  end

  @doc """
  Rewrites each secret in `snapshot` back to the keyring sentinel wherever
  `persisted` holds the sentinel, so a snapshot carrying boot-resolved
  values can be compared against the persisted config without reading the
  OS keychain. Pure — no keychain access.

  A secret that is absent from `snapshot` is left absent: the persisted
  config then still differs, which correctly signals a restart.
  """
  @spec mask_resolved_secrets(snapshot(), snapshot()) :: snapshot()
  def mask_resolved_secrets(snapshot, persisted)
      when is_map(snapshot) and is_map(persisted) do
    Enum.reduce(SecretPaths.all(), snapshot, fn secret, acc ->
      persisted_value = get_snapshot_value(persisted, secret.path)
      current_value = get_snapshot_value(acc, secret.path)

      if SecretWriter.sentinel?(persisted_value) and not is_nil(current_value) do
        put_snapshot_value(acc, secret.path, persisted_value)
      else
        acc
      end
    end)
  end

  @spec plaintext_secrets(snapshot()) :: [map()]
  def plaintext_secrets(snapshot) when is_map(snapshot) do
    SecretPaths.all()
    |> Enum.flat_map(fn secret ->
      value = get_snapshot_value(snapshot, secret.path)

      if plaintext_secret?(value) do
        [Map.put(secret, :value, value)]
      else
        []
      end
    end)
  end

  @spec get_snapshot_value(term(), path()) :: term()
  def get_snapshot_value(%{} = snapshot, [key]), do: Map.get(snapshot, key)

  def get_snapshot_value(%{} = snapshot, [key | rest]) do
    snapshot
    |> Map.get(key, [])
    |> get_snapshot_value(rest)
  end

  def get_snapshot_value(keyword, [key]) when is_list(keyword) and is_atom(key),
    do: Keyword.get(keyword, key)

  def get_snapshot_value(keyword, [key | rest]) when is_list(keyword) and is_atom(key) do
    keyword
    |> Keyword.get(key, [])
    |> get_snapshot_value(rest)
  end

  # Shape mismatch (e.g. a string key like "google" against a keyword list, or
  # a scalar mid-path) means the path is simply absent in this snapshot.
  def get_snapshot_value(_value, _path), do: nil

  @spec put_snapshot_value(snapshot() | keyword(), path(), term()) :: snapshot() | keyword()
  def put_snapshot_value(%{} = snapshot, [key], value), do: Map.put(snapshot, key, value)

  def put_snapshot_value(%{} = snapshot, [key | rest], value) do
    nested = Map.get(snapshot, key) || empty_container(rest)
    Map.put(snapshot, key, put_snapshot_value(nested, rest, value))
  end

  def put_snapshot_value(keyword, [key], value) when is_list(keyword) and is_atom(key) do
    Keyword.put(keyword, key, value)
  end

  def put_snapshot_value(keyword, [key | rest], value)
      when is_list(keyword) and is_atom(key) do
    nested = Keyword.get(keyword, key) || empty_container(rest)
    Keyword.put(keyword, key, put_snapshot_value(nested, rest, value))
  end

  # Missing sections materialize as the container the NEXT path key needs:
  # atom keys live in keyword lists, string keys (e.g. oauth's "google") in maps.
  defp empty_container([key | _rest]) when is_atom(key), do: []
  defp empty_container(_path), do: %{}

  @spec delete_snapshot_value(term(), path()) :: term()
  def delete_snapshot_value(%{} = snapshot, [key]), do: Map.delete(snapshot, key)

  def delete_snapshot_value(%{} = snapshot, [key | rest]) do
    Map.update(snapshot, key, [], &delete_snapshot_value(&1, rest))
  end

  def delete_snapshot_value(keyword, [key]) when is_list(keyword) and is_atom(key),
    do: Keyword.delete(keyword, key)

  def delete_snapshot_value(keyword, [key | rest]) when is_list(keyword) and is_atom(key) do
    Keyword.update(keyword, key, [], &delete_snapshot_value(&1, rest))
  end

  # Shape mismatch: nothing at this path to delete.
  def delete_snapshot_value(value, _path), do: value

  defp secure_secret(snapshot, previous, secret, write_opts, verdicts) do
    value = get_snapshot_value(snapshot, secret.path)
    old_value = previous_value(previous, secret.path)
    verdict = Map.get(verdicts, write_opts[:store])

    cond do
      not plaintext_secret?(value) ->
        {:ok, snapshot}

      SecretWriter.sentinel?(old_value) ->
        keep_or_rotate(snapshot, secret, value, write_opts, old_value, verdicts)

      # A store that answers takes every plaintext value, changed or not: that
      # is how a hand-edited key reaches the keyring on the next save.
      SecretWriter.usable?(verdict) ->
        write_secret(snapshot, secret, value, write_opts)

      # The store cannot be used, and this exact plaintext is already what's
      # on disk: keep it rather than failing an unrelated save (the load-time
      # plaintext warning keeps nagging), and never push it at a locked or
      # absent store. Only NEW or CHANGED secrets fail loud, below.
      value == old_value ->
        {:ok, snapshot}

      true ->
        {:error, SecretWriter.format_store_error(secret.key, {:verdict, verdict})}
    end
  end

  # Disk already says @keyring. Most saves arrive here with the RESOLVED runtime
  # value (every loaded snapshot carries it), so compare it against what's stored:
  #
  #   {:ok, ^value} → unchanged; keep the sentinel, no write.
  #   {:ok, _other} → genuine rotation; write the new value through, or it would be
  #                   silently dropped in favor of the stale stored one.
  #   {:error, _}   → keychain unreadable (locked / timeout / unavailable). Do NOT
  #                   escalate to a write: the on-disk value is already the @keyring
  #                   sentinel, so preserve it rather than failing this otherwise-
  #                   unrelated save (e.g. a routing-config or sandbox-grant commit).
  #                   A real rotation is re-detected on the next save once the
  #                   keychain is reachable. Only a positively-confirmed different
  #                   stored value triggers a write.
  # Disk already says a sentinel. Most saves arrive here with the RESOLVED
  # runtime value (every loaded snapshot carries it), so compare it against
  # what the store the sentinel names holds:
  #
  #   store unusable → keep the sentinel without asking: a locked keyring is
  #                    not read (that read is what raises the unlock dialog),
  #                    and a real rotation is re-detected on the next save once
  #                    the store answers.
  #   {:ok, ^value}  → unchanged; keep the sentinel, no write.
  #   {:ok, _other}  → a genuine rotation; write the new value through to the
  #                    configured store, or it would be dropped for the stale
  #                    stored one. When that is the other store, the sentinel
  #                    moves with the value and the stale item is removed from
  #                    the store it left, or the log says it could not be.
  #   {:error, _}    → unreadable right now; keep the sentinel rather than
  #                    failing an otherwise unrelated save.
  defp keep_or_rotate(snapshot, secret, value, write_opts, old_sentinel, verdicts) do
    {:ok, old_store} = SecretWriter.store_of_sentinel(old_sentinel)
    read_opts = Keyword.put(write_opts, :store, old_store)

    if SecretWriter.usable?(Map.fetch!(verdicts, old_store)) do
      case SecretWriter.get(secret.key, read_opts) do
        {:ok, ^value} -> {:ok, keep_sentinel(snapshot, secret, old_sentinel)}
        {:ok, _other} -> rotate(snapshot, secret, value, write_opts, read_opts, verdicts)
        {:error, _reason} -> {:ok, keep_sentinel(snapshot, secret, old_sentinel)}
      end
    else
      {:ok, keep_sentinel(snapshot, secret, old_sentinel)}
    end
  end

  defp rotate(snapshot, secret, value, write_opts, read_opts, verdicts) do
    verdict = Map.fetch!(verdicts, write_opts[:store])

    cond do
      not SecretWriter.usable?(verdict) ->
        {:error, SecretWriter.format_store_error(secret.key, {:verdict, verdict})}

      read_opts[:store] == write_opts[:store] ->
        write_secret(snapshot, secret, value, write_opts)

      true ->
        with {:ok, updated} <- write_secret(snapshot, secret, value, write_opts) do
          remove_stale_item(secret, read_opts)
          {:ok, updated}
        end
    end
  end

  defp keep_sentinel(snapshot, secret, sentinel) do
    put_snapshot_value(snapshot, secret.path, sentinel)
  end

  defp write_secret(snapshot, secret, value, write_opts) do
    case SecretWriteLog.put(secret.key, value, write_opts) do
      :ok ->
        {:ok,
         put_snapshot_value(snapshot, secret.path, SecretWriter.current_sentinel(write_opts))}

      {:error, reason} ->
        {:error, SecretWriter.format_store_error(secret.key, reason)}
    end
  end

  defp remove_stale_item(secret, read_opts) do
    case SecretWriter.delete(secret.key, read_opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "#{secret.env} moved to the #{read_opts[:store] |> other_store()} store, but the old " <>
            "copy could not be removed from the #{read_opts[:store]} store: #{inspect(reason)}"
        )
    end
  end

  defp other_store(:keyring), do: :file
  defp other_store(:file), do: :keyring

  defp previous_value(%{} = previous, path), do: get_snapshot_value(previous, path)
  defp previous_value(_previous, _path), do: nil

  # The snapshot's profile names the keychain namespace its secrets resolve
  # from. Read it here (not from app env) so each snapshot resolves against its
  # own profile — at boot, app env is not yet populated. Default/blank →
  # "general" (the legacy bare `fermix:<ENV>` coordinate).
  defp profile_of(snapshot) do
    case get_snapshot_value(snapshot, [:fermix_core, :profile]) do
      name when is_binary(name) and name != "" -> name
      _ -> SecretWriter.default_profile()
    end
  end

  # The snapshot's own store choice, for the same reason as the profile: a
  # save carries the setting it is saving, and at boot app env is not yet
  # populated. A value the loader let through is one `parse_store/1` accepts.
  defp store_of(snapshot) do
    case SecretWriter.parse_store(get_snapshot_value(snapshot, [:fermix_core, :secret_store])) do
      {:ok, store} -> store
      {:error, sentence} -> raise ArgumentError, sentence
    end
  end

  defp warn_unusable_store(verdict, secrets) do
    names = Enum.map_join(secrets, ", ", & &1.env)

    Logger.warning(
      "the #{verdict.store} secret store is not usable (#{verdict.sentence}), so " <>
        "#{names} stay unresolved until it is. `fermix doctor` shows the store's state."
    )
  end

  defp handle_keyring_resolution_error(snapshot, %{optional?: true} = secret, reason, warn?) do
    if warn?, do: warn_optional_secret(secret, reason)
    snapshot
  end

  # A REQUIRED secret that cannot be resolved (locked/slow login keychain →
  # `security` timeout, or a momentarily-unreadable entry) must NOT crash the
  # daemon at boot. Resolving this used to raise, and because it runs inside
  # BootReport.init / runtime.exs config hydration, the raise took down the whole
  # node — leaving the setup UI (the recovery surface) unreachable. Warn loudly and
  # leave the @keyring sentinel in place (exactly what optional secrets do): the
  # daemon boots, and the secret resolves on the next boot once the keychain is
  # reachable. Leaving the sentinel (vs blanking it) means a config save while the
  # keychain is down round-trips it untouched instead of orphaning the stored key.
  defp handle_keyring_resolution_error(snapshot, secret, reason, warn?) do
    if warn?, do: warn_required_secret(secret, reason)
    snapshot
  end

  defp warn_plaintext_secret(secret) do
    Logger.warning(
      "#{ConfigStore.path()} contains plaintext #{secret.env}; run `fermix setup --migrate-secrets`"
    )
  end

  defp warn_optional_secret(secret, reason) do
    Logger.warning(
      "#{SecretWriter.format_error(secret.key, reason)} #{secret.functionality} will fail until " <>
        "the secret is available. Run `fermix setup` to re-save it, or remove the stale " <>
        "@keyring value from #{ConfigStore.path()} if you do not use that functionality."
    )
  end

  defp warn_required_secret(secret, reason) do
    Logger.error(
      "#{SecretWriter.format_error(secret.key, reason)} Fermix started without #{secret.env}; " <>
        "the capability that needs it is unavailable until the keychain is reachable. Unlock " <>
        "your login keychain and restart, or re-save it with `fermix setup`."
    )
  end

  defp plaintext_secret?(value) when is_binary(value) do
    not SecretWriter.sentinel?(value) and String.trim(value) != ""
  end

  defp plaintext_secret?(_value), do: false
end
