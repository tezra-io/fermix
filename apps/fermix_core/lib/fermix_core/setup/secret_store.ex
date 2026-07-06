defmodule FermixCore.Setup.SecretStore do
  @moduledoc """
  Snapshot helpers for setup-managed secrets.

  `SecretPaths` is the registry. Any value at a registered path is stored
  through `SecretWriter` before the snapshot is written to disk.
  """

  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.SecretPaths
  alias FermixCore.Setup.SecretWriter

  require Logger

  @type snapshot :: map()
  @type path :: [atom() | String.t()]

  @spec secure_snapshot(snapshot(), keyword()) :: {:ok, snapshot()} | {:error, String.t()}
  def secure_snapshot(snapshot, opts \\ []) when is_map(snapshot) and is_list(opts) do
    previous = Keyword.get(opts, :previous)
    profile = profile_of(snapshot)

    Enum.reduce_while(SecretPaths.all(), {:ok, snapshot}, fn secret, {:ok, acc} ->
      case secure_secret(acc, previous, secret, profile) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec resolve_sentinels(snapshot(), keyword()) :: snapshot()
  def resolve_sentinels(snapshot, opts) when is_map(snapshot) and is_list(opts) do
    warn_plaintext? = Keyword.fetch!(opts, :warn_plaintext)
    profile = profile_of(snapshot)

    Enum.reduce(SecretPaths.all(), snapshot, fn secret, acc ->
      value = get_snapshot_value(acc, secret.path)
      resolve_secret_value(acc, secret, value, warn_plaintext?, profile)
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

  defp secure_secret(snapshot, previous, secret, profile) do
    value = get_snapshot_value(snapshot, secret.path)
    old_value = previous_value(previous, secret.path)

    cond do
      not plaintext_secret?(value) ->
        {:ok, snapshot}

      old_value == SecretWriter.sentinel() ->
        keep_or_rotate(snapshot, secret, value, profile)

      SecretWriter.available?() ->
        write_secret(snapshot, secret, value, profile)

      # No OS secret writer, but this exact plaintext is already what's on
      # disk: keep it rather than failing an unrelated save (the load-time
      # plaintext warning keeps nagging). Only NEW/CHANGED secrets require a
      # writer — those fail loud below.
      value == old_value ->
        {:ok, snapshot}

      true ->
        {:error, SecretWriter.format_store_error(secret.key, :unavailable)}
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
  defp keep_or_rotate(snapshot, secret, value, profile) do
    case SecretWriter.get(secret.key, profile: profile) do
      {:ok, ^value} -> {:ok, keep_sentinel(snapshot, secret)}
      {:ok, _other} -> write_secret(snapshot, secret, value, profile)
      {:error, _reason} -> {:ok, keep_sentinel(snapshot, secret)}
    end
  end

  defp keep_sentinel(snapshot, secret) do
    put_snapshot_value(snapshot, secret.path, SecretWriter.sentinel())
  end

  defp write_secret(snapshot, secret, value, profile) do
    case SecretWriter.put(secret.key, value, profile: profile) do
      :ok ->
        {:ok, put_snapshot_value(snapshot, secret.path, SecretWriter.sentinel())}

      {:error, reason} ->
        {:error, SecretWriter.format_store_error(secret.key, reason)}
    end
  end

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

  defp resolve_secret_value(snapshot, secret, value, warn_plaintext?, profile) do
    cond do
      value == SecretWriter.sentinel() ->
        resolve_keyring_secret(snapshot, secret, warn_plaintext?, profile)

      plaintext_secret?(value) ->
        if warn_plaintext?, do: warn_plaintext_secret(secret)
        snapshot

      true ->
        snapshot
    end
  end

  defp resolve_keyring_secret(snapshot, secret, warn?, profile) do
    case SecretWriter.get(secret.key, profile: profile) do
      {:ok, value} -> put_snapshot_value(snapshot, secret.path, value)
      {:error, reason} -> handle_keyring_resolution_error(snapshot, secret, reason, warn?)
    end
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
    value != SecretWriter.sentinel() and String.trim(value) != ""
  end

  defp plaintext_secret?(_value), do: false
end
