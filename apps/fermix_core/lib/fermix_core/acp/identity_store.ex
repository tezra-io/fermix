defmodule FermixCore.Acp.IdentityStore do
  @moduledoc """
  Durable custody for client-presented ACP identities: one 0600 JSON record per
  identity under `$FERMIX_HOME/acp_identities/`, in a 0700 directory
  (`MILESTONE_29_ACP_AGENT_SURFACE.md` §17.2).

  Every discipline is `FermixCore.Auth.Store`'s — atomic publish, permissions
  validated on read, a record that will not parse preserved as
  `<id>.json.broken.<ts>` and refused loudly — but deliberately *not*
  `auth.json` itself: that file's normalize hard-requires an access token, and
  four readers assume a refreshable, expiring credential. A relay signing key is
  none of those.

  ## The filename is the serializer

  There is no lock and no singleton writer. `Auth.Store` can do without one
  because its callers are serialized in-process; here the writers are N `Peer`
  processes (a Buzz bridge pool is 10 by default) and the deleter — `fermix acp
  forget` — runs in a different VM entirely, where an in-process lock could not
  reach.

  One file per identity removes the read-modify-write that would lose updates:
  a whole-file write *is* the record, and two agents write two paths. The create
  path is an atomic `:file.make_link/2` onto the target, so among N concurrent
  first presentations exactly one process learns it created the record and logs
  the single consent line. An unchanged re-presentation drops its temp file and
  writes nothing.
  """

  require Logger

  alias FermixCore.Acp.Identity
  alias FermixCore.Nostr.Key

  @version 1
  @extension ".json"

  @type outcome :: :created | :updated | :unchanged

  @doc """
  Persist a presentation. Creates the record on first sight, replaces it
  wholesale when any material field changed (preserving `first_seen`), and
  writes nothing at all when it did not.

  An identity-less record is never persisted (§17.5), so passing one is a caller
  bug and raises rather than writing a record with no name.
  """
  @spec upsert(Identity.t(), Path.t()) :: {:ok, outcome()} | {:error, term()}
  def upsert(identity, dir \\ dir())

  def upsert(
        %Identity{id: id, first_seen: %DateTime{}, last_seen: %DateTime{}} = identity,
        dir
      )
      when is_binary(id) and is_binary(dir) do
    with {:ok, npub} <- validate_id(id),
         :ok <- ensure_dir(dir) do
      publish(identity, npub, record_path(dir, id))
    end
  end

  @doc "Read one record. The three failure kinds are named apart (§17.3)."
  @spec fetch(String.t(), Path.t()) :: {:ok, Identity.t()} | {:error, term()}
  def fetch(id, dir \\ dir()) when is_binary(id) and is_binary(dir) do
    with {:ok, _npub} <- validate_id(id) do
      read_record(id, record_path(dir, id))
    end
  end

  @doc """
  Every record in the store, filename order, as a result per record: an
  unreadable one is reported, never dropped.
  """
  @spec list(Path.t()) :: [{:ok, Identity.t()} | {:error, term()}]
  def list(dir \\ dir()) when is_binary(dir) do
    case record_ids(dir) do
      {:ok, ids} -> Enum.map(ids, &fetch(&1, dir))
      {:error, reason} -> [{:error, {:identity_dir_unreadable, dir, reason}}]
    end
  end

  @doc "Disconnect one identity. Deleting the record file *is* the sever."
  @spec forget(String.t(), Path.t()) :: :ok | {:error, term()}
  def forget(id, dir \\ dir()) when is_binary(id) and is_binary(dir) do
    with {:ok, _npub} <- validate_id(id) do
      delete(id, record_path(dir, id))
    end
  end

  @doc """
  Disconnect every identity. Quarantined `.broken.<ts>` evidence is left in
  place — it is not a credential.
  """
  @spec forget_all(Path.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def forget_all(dir \\ dir()) when is_binary(dir) do
    case record_ids(dir) do
      {:ok, ids} -> forget_each(ids, dir)
      {:error, reason} -> {:error, {:identity_dir_unreadable, dir, reason}}
    end
  end

  @doc "The store directory. One derivation, so doctor and the daemon agree."
  @spec dir() :: Path.t()
  def dir do
    home = System.get_env("FERMIX_HOME") || Path.join(System.user_home!(), ".fermix")
    Path.join(home, "acp_identities")
  end

  # --- write ---

  defp publish(identity, npub, path) do
    tmp = tmp_path(path)

    with :ok <- write_tmp(path, tmp, encode(identity)) do
      link_or_reconcile(identity, npub, path, tmp)
    end
  end

  defp link_or_reconcile(identity, npub, path, tmp) do
    case :file.make_link(tmp, path) do
      :ok -> created(npub, path, tmp)
      {:error, :eexist} -> reconcile(identity, npub, path, tmp)
      {:error, reason} -> discard(tmp, {:error, {:identity_write_failed, path, reason}})
    end
  end

  defp created(npub, path, tmp) do
    _ = File.rm(tmp)
    Logger.info("Acp.IdentityStore: connected buzz identity #{npub} — record at #{path}")
    {:ok, :created}
  end

  defp reconcile(identity, npub, path, tmp) do
    case read_record(identity.id, path) do
      {:ok, stored} -> replace_if_changed(identity, stored, npub, path, tmp)
      {:error, reason} -> discard(tmp, {:error, reason})
    end
  end

  defp replace_if_changed(identity, stored, npub, path, tmp) do
    case material(identity) == material(stored) do
      true -> discard(tmp, {:ok, :unchanged})
      false -> replace(%{identity | first_seen: stored.first_seen}, npub, path, tmp)
    end
  end

  defp replace(identity, npub, path, tmp) do
    with :ok <- write_tmp(path, tmp, encode(identity)),
         :ok <- File.rename(tmp, path) do
      Logger.info("Acp.IdentityStore: refreshed buzz identity #{npub} — record at #{path}")
      {:ok, :updated}
    else
      {:error, reason} -> discard(tmp, {:error, {:identity_write_failed, path, reason}})
    end
  end

  defp write_tmp(path, tmp, contents) do
    with :ok <- File.write(tmp, contents, [:binary]),
         :ok <- File.chmod(tmp, 0o600) do
      :ok
    else
      {:error, reason} -> {:error, {:identity_write_failed, path, reason}}
    end
  end

  defp discard(tmp, result) do
    _ = File.rm(tmp)
    result
  end

  defp ensure_dir(dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700) do
      :ok
    else
      {:error, reason} -> {:error, {:identity_dir_unwritable, dir, reason}}
    end
  end

  # Timestamps are bookkeeping, not identity: everything else is material, and a
  # field added later joins this comparison by default.
  defp material(%Identity{} = identity),
    do: identity |> Map.from_struct() |> Map.drop([:first_seen, :last_seen])

  # --- read ---

  defp read_record(id, path) do
    with :ok <- check_permissions(id, path),
         {:ok, raw} <- read_raw(id, path) do
      decode(id, path, raw)
    end
  end

  defp read_raw(id, path) do
    case File.read(path) do
      {:ok, raw} -> {:ok, raw}
      {:error, :enoent} -> {:error, {:identity_missing, id, path}}
      {:error, reason} -> {:error, {:identity_unreadable, id, path, reason}}
    end
  end

  defp check_permissions(id, path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} -> check_mode(id, path, Bitwise.band(mode, 0o777))
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:identity_unreadable, id, path, reason}}
    end
  end

  defp check_mode(_id, _path, 0o600), do: :ok

  defp check_mode(id, path, mode) do
    Logger.error(
      "Acp.IdentityStore: #{path} has perms 0o#{Integer.to_string(mode, 8)} (expected 0o600). " <>
        "Run `chmod 600 #{path}` and restart."
    )

    {:error, {:identity_permissions, id, path, mode}}
  end

  defp decode(id, path, raw) do
    case Jason.decode(raw) do
      {:ok, data} -> from_json(id, path, raw, data)
      {:error, %Jason.DecodeError{position: at}} -> quarantine(id, path, raw, {:invalid_json, at})
    end
  end

  defp from_json(id, path, raw, data) do
    with :ok <- check_version(data),
         :ok <- check_kind(data),
         :ok <- check_id(data, id),
         {:ok, first_seen} <- timestamp(data, "first_seen"),
         {:ok, last_seen} <- timestamp(data, "last_seen") do
      {:ok, to_identity(id, data, first_seen, last_seen)}
    else
      {:error, {:unsupported, detail}} -> {:error, {:identity_unsupported, id, path, detail}}
      {:error, reason} -> quarantine(id, path, raw, reason)
    end
  end

  defp check_version(%{"version" => @version}), do: :ok
  defp check_version(%{"version" => other}), do: {:error, {:unsupported, {:version, other}}}
  defp check_version(_data), do: {:error, {:missing_field, "version"}}

  defp check_kind(%{"kind" => "buzz"}), do: :ok
  defp check_kind(%{"kind" => other}), do: {:error, {:unsupported, {:kind, other}}}
  defp check_kind(_data), do: {:error, {:missing_field, "kind"}}

  defp check_id(%{"id" => id}, id), do: :ok
  defp check_id(%{"id" => stored}, _id), do: {:error, {:id_mismatch, stored}}
  defp check_id(_data, _id), do: {:error, {:missing_field, "id"}}

  defp timestamp(data, field) do
    with value when is_binary(value) <- Map.get(data, field),
         {:ok, at, _offset} <- DateTime.from_iso8601(value) do
      {:ok, at}
    else
      _invalid -> {:error, {:invalid_timestamp, field}}
    end
  end

  defp to_identity(id, data, first_seen, last_seen) do
    %Identity{
      id: id,
      kind: :buzz,
      display_name: string_or_nil(data["display_name"]),
      relay_url: string_or_nil(data["relay_url"]),
      auth_tag: string_or_nil(data["auth_tag"]),
      path: string_or_nil(data["path"]),
      git_config: string_map(data["git_config"]),
      secrets: string_map(data["secrets"]),
      first_seen: first_seen,
      last_seen: last_seen
    }
  end

  # The record's own bytes never reach the log or the reason: a malformed record
  # may still hold a signing key.
  defp quarantine(id, path, raw, reason) do
    backup = "#{path}.broken.#{System.system_time(:second)}"

    case File.write(backup, raw, [:binary]) do
      :ok -> preserved(id, path, backup, reason)
      {:error, error} -> {:error, {:identity_quarantine_failed, id, path, reason, error}}
    end
  end

  defp preserved(id, path, backup, reason) do
    _ = File.chmod(backup, 0o600)
    _ = File.rm(path)

    Logger.error(
      "Acp.IdentityStore: refusing #{path} (#{inspect(reason)}); preserved at #{backup}. " <>
        "Reconnect the client to re-present its credentials."
    )

    {:error, {:identity_quarantined, id, path, backup, reason}}
  end

  # --- delete ---

  defp delete(id, path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> {:error, {:identity_missing, id, path}}
      {:error, reason} -> {:error, {:identity_delete_failed, id, path, reason}}
    end
  end

  defp forget_each(ids, dir) do
    results = Enum.map(ids, &forget(&1, dir))

    case Enum.find(results, &(&1 != :ok)) do
      nil -> {:ok, length(ids)}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- paths ---

  defp validate_id(id) do
    case Key.npub(id) do
      {:ok, npub} -> {:ok, npub}
      {:error, _reason} -> {:error, {:invalid_identity_id, id}}
    end
  end

  defp record_path(dir, id), do: Path.join(dir, id <> @extension)

  defp tmp_path(path), do: "#{path}.tmp.#{System.unique_integer([:positive, :monotonic])}"

  defp record_ids(dir) do
    case File.ls(dir) do
      {:ok, entries} -> {:ok, entries |> Enum.flat_map(&record_id/1) |> Enum.sort()}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  # A temp file or a `.broken.<ts>` sibling is not a record — the id must be the
  # whole basename, so `<id>.json.tmp.7` and `<id>.json.broken.9` are skipped.
  defp record_id(entry) do
    with true <- String.ends_with?(entry, @extension),
         id <- String.replace_suffix(entry, @extension, ""),
         {:ok, _npub} <- validate_id(id) do
      [id]
    else
      _other -> []
    end
  end

  # --- json ---

  defp encode(%Identity{} = identity) do
    Jason.encode!(
      %{
        "version" => @version,
        "id" => identity.id,
        "kind" => Atom.to_string(identity.kind),
        "display_name" => identity.display_name,
        "relay_url" => identity.relay_url,
        "auth_tag" => identity.auth_tag,
        "path" => identity.path,
        "git_config" => identity.git_config,
        "secrets" => identity.secrets,
        "first_seen" => DateTime.to_iso8601(identity.first_seen),
        "last_seen" => DateTime.to_iso8601(identity.last_seen)
      },
      pretty: true
    ) <> "\n"
  end

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp string_map(value) when is_map(value), do: Map.new(Enum.filter(value, &string_pair?/1))
  defp string_map(_value), do: %{}

  defp string_pair?({key, value}), do: is_binary(key) and is_binary(value)
end
