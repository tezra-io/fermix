defmodule FermixCore.Plugins.Dist.Provenance.Snapshot do
  @moduledoc """
  The immutable result of a passed provenance gate: the plugin tree as bytes,
  decoded from the verified archive binary and never from the mutable installed
  directory.

  Registry, manifest decoding, skill/reference loading, and UI asset reads for a
  generation consume this map. A filesystem edit, symlink, or directory swap
  after verification therefore cannot change bytes already in use — it is
  detected on the next start, when the gate recomputes the active tree digest.
  """

  @enforce_keys [:name, :version, :tree_digest, :artifact_sha256, :files, :verified_at]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          tree_digest: String.t(),
          artifact_sha256: String.t(),
          files: %{String.t() => binary()},
          verified_at: DateTime.t()
        }

  @doc "Verified bytes at `path` (NFC-normalized, archive-relative), or an error."
  @spec fetch(t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch(%__MODULE__{files: files}, path) when is_binary(path) do
    case Map.fetch(files, path) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, {:not_in_snapshot, path}}
    end
  end

  @doc "Every verified path in the snapshot, sorted."
  @spec paths(t()) :: [String.t()]
  def paths(%__MODULE__{files: files}), do: files |> Map.keys() |> Enum.sort()
end

defmodule FermixCore.Plugins.Dist.Provenance do
  @moduledoc """
  The provenance gate for `remote_mcp` plugins (M27 §9.3, §10.2).

  A remote manifest binds a live credential to a network endpoint and ships no
  code to review at runtime, so it is runnable **only** from an artifact
  installed through the static-catalog path whose evidence re-verifies. Before
  Registry parses the manifest, exposes its skill, registers its auth path, or
  resolves a credential, `verify/3`:

    1. opens the cached archive **once**, reads it within the artifact byte/file
       caps into a generation-owned binary, and never reopens that path;
    2. verifies that binary's checksum and the **publisher** artifact
       signature/certificate against the pinned `fermix-plugins`
       release-workflow identity;
    3. safely decodes the **same binary** into an immutable normalized
       `{relative_path => bytes}` snapshot;
    4. derives `tree_digest_v2` from that snapshot; and
    5. computes the digest of the **active installed tree** and matches it
       against the derived one as a tamper signal.

  ## The trust chain

      publisher signature over the archive
        -> archive bytes
        -> snapshot
        -> tree_digest_v2
        -> compare to the active installed tree

  Every link is derived from the signed bytes. The locally editable
  `installed.json` is an evidence *locator* only and is never the trust root:
  the digest is never matched against a lockfile value, so rewriting the
  lockfile to describe a tampered tree authorizes nothing.

  Current-catalog membership is not proof either, so a verified install stays
  loadable after its version leaves the shipping catalog: a yank blocks new
  installs and upgrades without becoming an implicit kill switch.

  An unsigned `dev_local` (or bundled) remote manifest has no evidence and is
  non-runnable: `{:error, :unverified_remote_runtime}`. Core tests inject
  explicit fake server specs instead.

  ## Scope reduction: the catalog receipt was removed (operator-approved)

  An earlier revision carried a SECOND signature — a Fermix "catalog receipt"
  proving Fermix *curated* the artifact, distinct from the publisher signature
  proving who *built* it (§9.3: "the plugin artifact signature alone proves
  publisher workflow authorship, not curation"). Two facts retired it:

    * Fermix is currently both publisher and curator — every plugin in
      `fermix-plugins` is first-party — so the single publisher signature
      already carries both facts and the second one added no independent
      authority.
    * The receipt required a catalog-approval CI workflow that does not exist,
      leaving the gate fail-closed and unusable.

  This is a deliberate reduction, not an oversight. Restoring curation as a
  distinct claim (once a third party can publish) means restoring the receipt
  *together with* the workflow that mints it — a signature nobody issues is not
  a control.

  The one signature goes through the existing `Dist.Verifier` seam tagged
  `artifact: :plugin`, keeping it pinned to the publisher release-workflow
  identity.
  """

  alias FermixCore.Plugins.Dist.Provenance.Snapshot
  alias FermixCore.Plugins.Dist.SafeRm
  alias FermixCore.Plugins.Dist.Store
  alias FermixCore.Plugins.Dist.TreeDigest
  alias FermixCore.Plugins.Dist.Verifier.Cosign, as: VerifierCosign

  @remote_kind "remote_mcp"

  # Same 100 MB ceiling `Archive` applies to an artifact's declared uncompressed
  # bytes, here bounding the compressed blob a generation holds in memory.
  @max_archive_bytes 100 * 1024 * 1024
  @max_checksum_bytes 128
  @max_snapshot_files 4_096

  @evidence %{
    archive: "artifact.tgz",
    sig: "artifact.sig",
    cert: "artifact.pem",
    sha256: "artifact.sha256"
  }

  @evidence_material [:archive, :sig, :cert]

  @type source :: {:installed, Path.t()} | :dev_local | :bundled

  @doc """
  Whether a manifest `runtime` block declares the remote MCP runtime — the one
  authority on "is this plugin gated". Callers pass the block itself
  (`manifest["runtime"]` / `%Plugin{}.runtime`), which may be `nil`.
  """
  @spec remote_runtime?(map() | nil) :: boolean()
  def remote_runtime?(%{"kind" => @remote_kind}), do: true
  def remote_runtime?(runtime) when is_map(runtime) or is_nil(runtime), do: false

  @doc "The runtime kind string this gate covers."
  @spec remote_kind() :: String.t()
  def remote_kind, do: @remote_kind

  @doc """
  Run the gate for the active version of `name`. Returns the verified snapshot,
  or a specific refusal — every refusal happens before any untrusted manifest,
  skill, or credential is touched.

  `opts`: `:verifier` (the `Dist.Verifier` seam). Resolution follows the same
  shape as `Setup.SecretWriter`: an explicit option wins, else the configured
  `:plugin_provenance_verifier`, else cosign. `Registry.find/1` has no options to
  thread, so the configured seam is the only way a test reaches this gate.
  """
  @spec verify(source(), String.t(), keyword()) :: {:ok, Snapshot.t()} | {:error, term()}
  def verify(source, name, opts \\ [])

  def verify({:installed, root}, name, opts)
      when is_binary(root) and is_binary(name) and is_list(opts) do
    case Store.active_version(root, name) do
      nil -> {:error, {:no_active_version, name}}
      version -> capture_and_verify(root, name, version, opts)
    end
  end

  def verify(source, name, opts)
      when source in [:dev_local, :bundled] and is_binary(name) and is_list(opts),
      do: {:error, :unverified_remote_runtime}

  @doc """
  Retain the evidence for a freshly installed version (§9.3): the original
  tarball, its published checksum, and the publisher signature material,
  written outside the loadable tree and keyed by version so an upgrade never
  overwrites the evidence of the version still active.

  `material` carries paths under `:archive`, `:sig`, `:cert` plus the published
  `:sha256` hex.
  """
  @spec retain(Path.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def retain(root, name, version, %{} = material)
      when is_binary(root) and is_binary(name) and is_binary(version) do
    with {:ok, sources} <- material_sources(material),
         {:ok, sha} <- checksum_hex(Map.get(material, :sha256)) do
      write_evidence(root, name, version, sources, sha)
    end
  end

  defp configured_verifier,
    do: Application.get_env(:fermix_core, :plugin_provenance_verifier, VerifierCosign)

  # --- capture (step 1) ---

  defp capture_and_verify(root, name, version, opts) do
    evidence = Store.evidence_dir(root, name, version)

    with {:ok, archive} <- capture(evidence, :archive, @max_archive_bytes),
         {:ok, recorded_sha} <- capture(evidence, :sha256, @max_checksum_bytes) do
      attempt = %{
        root: root,
        name: name,
        version: version,
        evidence: evidence,
        archive: archive,
        recorded_sha: String.trim(recorded_sha),
        sha256: sha256_hex(archive),
        verifier: Keyword.get(opts, :verifier) || configured_verifier()
      }

      with_scratch(root, fn scratch -> gate(attempt, scratch) end)
    end
  end

  # Read once, bounded. `lstat` (not `stat`) so an evidence path replaced by a
  # symlink is refused instead of followed, and the size is re-checked after the
  # read so a file that grew between the two calls cannot slip past the cap.
  defp capture(evidence, key, max_bytes) do
    path = Path.join(evidence, Map.fetch!(@evidence, key))

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= max_bytes <- File.lstat(path),
         {:ok, bytes} when byte_size(bytes) <= max_bytes <- File.read(path) do
      {:ok, bytes}
    else
      {:ok, %File.Stat{type: :regular, size: size}} -> {:error, {:evidence_too_large, key, size}}
      {:ok, %File.Stat{type: type}} -> {:error, {:evidence_not_a_file, key, type}}
      {:ok, bytes} when is_binary(bytes) -> {:error, {:evidence_too_large, key, byte_size(bytes)}}
      {:error, reason} -> {:error, {:evidence_unreadable, key, reason}}
    end
  end

  # --- the gate (steps 2-5) ---

  defp gate(attempt, scratch) do
    with :ok <- verify_artifact(attempt, scratch),
         {:ok, files} <- decode_snapshot(attempt.archive),
         {:ok, digest} <- TreeDigest.digest_files(files),
         :ok <- check_active_tree(attempt, digest),
         :ok <- check_snapshot_manifest(files, attempt) do
      {:ok, snapshot(attempt, digest, files)}
    end
  end

  # Step 2 pairs the two independent bindings on the held bytes: the checksum
  # the catalog published for this version, and the publisher workflow's
  # signature over the exact binary.
  #
  # The `Verifier` seam takes a path, so the captured bytes are written to a
  # private per-attempt scratch file and *that* is verified — the evidence path
  # is never reopened, and the snapshot is decoded from the same in-memory
  # binary that was signed over.
  defp verify_artifact(attempt, scratch) do
    blob = Path.join(scratch, "plugin.blob")

    with :ok <- match(attempt.sha256, attempt.recorded_sha, :artifact_checksum_mismatch),
         :ok <- write_scratch(blob, attempt.archive) do
      verify_signature(attempt, blob)
    end
  end

  defp verify_signature(attempt, blob) do
    sig = Path.join(attempt.evidence, @evidence.sig)
    cert = Path.join(attempt.evidence, @evidence.cert)

    case attempt.verifier.verify(blob, sig, cert,
           name: attempt.name,
           version: attempt.version,
           artifact: :plugin
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:verification_failed, :plugin, reason}}
    end
  end

  # The snapshot's digest is derived from the signed bytes; the active tree's is
  # read off disk. A mismatch means the loadable tree is no longer the artifact
  # that was signed — refuse rather than load either one.
  defp check_active_tree(attempt, digest) do
    dir = Store.version_dir(attempt.root, attempt.name, attempt.version)

    with {:ok, active} <- TreeDigest.digest_tree(dir) do
      match(active, digest, :active_tree_mismatch)
    end
  end

  # The gate is remote-only; the artifact's own verified manifest must agree it
  # is remote, or a local plugin could be loaded through the remote path (and
  # vice versa).
  defp check_snapshot_manifest(files, attempt) do
    with {:ok, raw} <- fetch_manifest(files),
         {:ok, manifest} when is_map(manifest) <- Jason.decode(raw),
         :ok <- match(manifest["name"], attempt.name, :snapshot_name_mismatch),
         :ok <- match(manifest["version"], attempt.version, :snapshot_version_mismatch) do
      check_snapshot_runtime(manifest["runtime"])
    else
      {:ok, _non_object} -> {:error, :snapshot_manifest_not_object}
      {:error, %Jason.DecodeError{}} -> {:error, :snapshot_manifest_invalid_json}
      {:error, _reason} = error -> error
    end
  end

  defp check_snapshot_runtime(runtime) do
    if remote_runtime?(runtime),
      do: :ok,
      else: {:error, {:snapshot_runtime_mismatch, runtime_kind(runtime)}}
  end

  defp runtime_kind(%{"kind" => kind}), do: kind
  defp runtime_kind(_runtime), do: nil

  defp fetch_manifest(files) do
    case Map.fetch(files, "plugin.json") do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, :snapshot_manifest_missing}
    end
  end

  defp snapshot(attempt, digest, files) do
    %Snapshot{
      name: attempt.name,
      version: attempt.version,
      tree_digest: digest,
      artifact_sha256: attempt.sha256,
      files: files,
      verified_at: DateTime.utc_now()
    }
  end

  # --- in-memory archive decode (step 3) ---

  # `Archive` owns the path form of these rules for install-time extraction;
  # this owns the binary form, because the gate must decode the bytes it holds
  # and never a file that could be swapped underneath it. It is deliberately
  # the stricter of the two — any member kind other than a regular file or a
  # directory is refused outright — so a divergence surfaces as a loud refusal.
  defp decode_snapshot(archive) do
    with {:ok, members} <- table(archive),
         {:ok, regular} <- validate_members(members),
         {:ok, entries} <- extract_memory(archive) do
      entries
      |> Enum.filter(fn {name, _bytes} -> MapSet.member?(regular, to_string(name)) end)
      |> normalize_entries()
    end
  end

  defp table(archive) do
    case :erl_tar.table({:binary, archive}, [:compressed, :verbose]) do
      {:ok, members} -> {:ok, members}
      {:error, reason} -> {:error, {:snapshot_table_failed, reason}}
    end
  end

  defp extract_memory(archive) do
    case :erl_tar.extract({:binary, archive}, [:compressed, :memory]) do
      {:ok, entries} -> {:ok, entries}
      {:error, reason} -> {:error, {:snapshot_extract_failed, reason}}
    end
  end

  # Validate every member, accumulating the regular-file names and their
  # declared uncompressed bytes; halt on the first unsafe member, once the
  # running total exceeds the archive cap, or once the file count does.
  defp validate_members(members) do
    members
    |> Enum.reduce_while({:ok, MapSet.new(), 0}, fn member, {:ok, names, total} ->
      case classify_member(member, names, total) do
        {:ok, next_names, next_total} -> {:cont, {:ok, next_names, next_total}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, names, _total} -> {:ok, names}
      {:error, _reason} = error -> error
    end
  end

  defp classify_member({name, type, size, _mtime, _mode, _uid, _gid}, names, total) do
    path = to_string(name)

    cond do
      path == "" -> {:error, {:unsafe_member, :invalid_name, path}}
      type in [:symlink, :link] -> {:error, {:unsafe_member, :link, path}}
      String.starts_with?(path, "/") -> {:error, {:unsafe_member, :absolute, path}}
      traversal?(path) -> {:error, {:unsafe_member, :traversal, path}}
      type == :directory -> {:ok, names, total}
      type != :regular -> {:error, {:unsafe_member, :not_a_regular_file, path}}
      true -> accumulate(names, total, path, size)
    end
  end

  defp accumulate(names, total, path, size) do
    next = total + size

    cond do
      next > @max_archive_bytes -> {:error, {:snapshot_too_large, next}}
      MapSet.size(names) >= @max_snapshot_files -> {:error, {:snapshot_too_many_files, path}}
      true -> {:ok, MapSet.put(names, path), next}
    end
  end

  defp traversal?(path), do: path |> Path.split() |> Enum.any?(&(&1 == ".."))

  # Archive-relative paths normalize to NFC — the same normalization
  # `TreeDigest` hashes under — and a duplicate after normalization is a hostile
  # ambiguity (two members, one loadable path), not a last-wins merge.
  defp normalize_entries(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {name, bytes}, {:ok, acc} ->
      case normalize_path(to_string(name)) do
        {:ok, path} -> put_entry(acc, path, bytes)
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp put_entry(acc, path, bytes) do
    if Map.has_key?(acc, path),
      do: {:halt, {:error, {:duplicate_snapshot_path, path}}},
      else: {:cont, {:ok, Map.put(acc, path, bytes)}}
  end

  defp normalize_path(raw) do
    stripped = String.replace_prefix(raw, "./", "")

    case :unicode.characters_to_nfc_binary(stripped) do
      "" -> {:error, {:unsafe_member, :invalid_name, raw}}
      path when is_binary(path) -> {:ok, path}
      _error -> {:error, {:invalid_path_encoding, raw}}
    end
  end

  # --- evidence retention ---

  defp material_sources(material) do
    Enum.reduce_while(@evidence_material, {:ok, []}, fn key, {:ok, acc} ->
      case Map.get(material, key) do
        path when is_binary(path) and path != "" -> {:cont, {:ok, [{key, path} | acc]}}
        _missing -> {:halt, {:error, {:missing_evidence_material, key}}}
      end
    end)
  end

  defp checksum_hex(sha) when is_binary(sha) do
    if hex64?(sha), do: {:ok, sha}, else: {:error, {:invalid_artifact_checksum, sha}}
  end

  defp checksum_hex(other), do: {:error, {:invalid_artifact_checksum, other}}

  defp write_evidence(root, name, version, sources, sha) do
    dest = Store.evidence_dir(root, name, version)
    staging = Path.join(Path.dirname(dest), "." <> Path.basename(dest) <> ".staging")
    _ = SafeRm.rm_rf(staging, root)
    File.mkdir_p!(staging)

    case stage_evidence(staging, sources, sha) do
      :ok -> replace_evidence(root, staging, dest)
      {:error, _reason} = error -> discard_staging(root, staging, error)
    end
  end

  defp stage_evidence(staging, sources, sha) do
    with :ok <- copy_sources(staging, sources) do
      write_scratch(Path.join(staging, @evidence.sha256), sha)
    end
  end

  defp copy_sources(staging, sources) do
    Enum.reduce_while(sources, :ok, fn {key, src}, :ok ->
      case File.cp(src, Path.join(staging, Map.fetch!(@evidence, key))) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:evidence_copy_failed, key, reason}}}
      end
    end)
  end

  defp replace_evidence(root, staging, dest) do
    File.mkdir_p!(Path.dirname(dest))

    with :ok <- SafeRm.rm_rf(dest, root),
         :ok <- File.rename(staging, dest) do
      :ok
    else
      {:error, reason} ->
        discard_staging(root, staging, {:error, {:evidence_write_failed, reason}})
    end
  end

  defp discard_staging(root, staging, error) do
    _ = SafeRm.rm_rf(staging, root)
    error
  end

  # --- helpers ---

  # Per-attempt scratch: created 0700, removed on every exit path including a
  # raise, and named so a crashed VM's copy is collected by the boot sweep.
  defp with_scratch(root, fun) do
    dir = Store.transient_run_dir(root, scratch_tag())
    File.mkdir_p!(dir)
    _ = File.chmod(dir, 0o700)

    try do
      fun.(dir)
    after
      SafeRm.rm_rf(dir, root)
    end
  end

  defp scratch_tag,
    do: "#{List.to_string(:os.getpid())}-#{System.unique_integer([:positive, :monotonic])}"

  defp write_scratch(path, bytes) do
    case File.write(path, bytes) do
      :ok -> :ok
      {:error, reason} -> {:error, {:scratch_write_failed, path, reason}}
    end
  end

  defp hex64?(value),
    do: is_binary(value) and byte_size(value) == 64 and value =~ ~r/\A[0-9a-f]{64}\z/

  defp sha256_hex(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp match(value, value, _tag), do: :ok
  defp match(got, expected, tag), do: {:error, {tag, expected, got}}
end
