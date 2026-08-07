defmodule FermixCore.Plugins.Dist.Provenance.Cache do
  @moduledoc """
  Per-generation memo for the `remote_mcp` provenance gate (M27 §9.3, §10.2).

  `Provenance.verify/3` spawns cosign and decodes the whole artifact, and
  `Registry.list/1` runs on the credential path (`Plugins.Auth`), the health and
  config paths, `fermix doctor`, the MCP seeder, and every CLI verb. Verifying on
  each of those would put an external process spawn in front of ordinary turns.

  So the gate runs **once per version per VM** and its verified manifest is
  memoized here. That is not a weakening of the check — it is the generation
  model `Provenance` already documents: the active-tree digest is recomputed when
  a generation starts, so tampering is caught at the next boot rather than
  mid-run, and the bytes a running generation already trusted cannot be changed
  underneath it by editing the directory.

  The key carries the store root and the memo carries the version, so an upgrade
  misses and re-verifies with no explicit invalidation, and two homes in one VM
  (a daemon and a test, or two `FERMIX_HOME`s) never share an entry.
  `invalidate/2` exists for uninstall, where the name disappears entirely.
  Failures are deliberately **not** cached: a cosign spawn that failed for a
  transient reason must not pin a refusal for the life of the VM.

  `:persistent_term` rather than an ETS table or a GenServer because this must
  work in the tree-less CLI VM as well as the daemon — a cache that only exists
  under a supervisor would send `fermix plugins list` down a different path than
  the daemon, which is the shape of bug this repo has been bitten by before.
  Writes are rare (once per version) and reads are free, which is exactly the
  access pattern `:persistent_term` is for.
  """

  alias FermixCore.Plugins.Dist.Provenance
  alias FermixCore.Plugins.Dist.Provenance.Snapshot
  alias FermixCore.Plugins.Dist.Store

  @doc """
  The verified manifest for the active version of an installed remote plugin.

  Runs the full gate on a miss and memoizes the decoded manifest; returns the
  memoized one when the active version is unchanged.

  `opts` is passed through to `Provenance.verify/3` (`:verifier`).
  """
  @spec verified_manifest(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verified_manifest(root, name, opts \\ [])
      when is_binary(root) and is_binary(name) and is_list(opts) do
    case Store.active_version(root, name) do
      nil -> {:error, {:no_active_version, name}}
      version -> fetch_or_verify(root, name, version, opts)
    end
  end

  @doc "Drop any memo for `name` under `root`. For uninstall; an upgrade misses on its own."
  @spec invalidate(Path.t(), String.t()) :: :ok
  def invalidate(root, name) when is_binary(root) and is_binary(name) do
    _ = :persistent_term.erase(key(root, name))
    :ok
  end

  defp fetch_or_verify(root, name, version, opts) do
    case :persistent_term.get(key(root, name), :miss) do
      {^version, manifest} -> {:ok, manifest}
      _miss_or_stale_version -> verify_and_memo(root, name, version, opts)
    end
  end

  defp verify_and_memo(root, name, version, opts) do
    with {:ok, snapshot} <- Provenance.verify({:installed, root}, name, opts),
         {:ok, manifest} <- decode_manifest(snapshot) do
      :persistent_term.put(key(root, name), {version, manifest})
      {:ok, manifest}
    end
  end

  # The manifest comes from the SIGNED bytes, never from the installed file that
  # was only used to decide the plugin is remote in the first place.
  defp decode_manifest(%Snapshot{} = snapshot) do
    with {:ok, raw} <- Snapshot.fetch(snapshot, "plugin.json"),
         {:ok, manifest} when is_map(manifest) <- Jason.decode(raw) do
      {:ok, manifest}
    else
      {:ok, _non_object} -> {:error, :snapshot_manifest_not_object}
      {:error, %Jason.DecodeError{}} -> {:error, :snapshot_manifest_invalid_json}
      {:error, _reason} = error -> error
    end
  end

  defp key(root, name), do: {__MODULE__, root, name}
end
