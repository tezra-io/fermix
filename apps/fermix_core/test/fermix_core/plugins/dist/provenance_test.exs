defmodule FermixCore.Plugins.Dist.ProvenanceVerifierStub do
  @moduledoc """
  Test `Verifier` for the provenance gate.

  Like `FermixTestSupport.DistVerifierStub` it **default-denies** — a forgotten
  `allow/3` fails the gate, never passes it by accident. It keys on the
  `:artifact` kind with `fetch!/2`, so a gate that stopped tagging its one
  signature as the publisher artifact fails loudly here. It also records the
  SHA-256 of the blob it was handed, so a test can prove cosign verified the
  bytes the gate captured rather than a path it reopened.
  """

  @behaviour FermixCore.Plugins.Dist.Verifier

  @table :provenance_verifier_stub

  def init do
    cleanup()
    :ets.new(@table, [:named_table, :public, :set])
    :ok
  end

  def cleanup do
    case :ets.whereis(@table) do
      :undefined -> :ok
      tid -> :ets.delete(tid)
    end
  end

  @doc "Allow exactly this `{kind, name, version}`; everything else is denied."
  def allow(kind, name, version) do
    :ets.insert(@table, {{kind, name, version}, :ok})
    :ok
  end

  @doc "SHA-256 of the blob last handed to the verifier for `kind`, or nil."
  def seen(kind) do
    case :ets.lookup(@table, {:seen, kind}) do
      [{_, sha}] -> sha
      [] -> nil
    end
  end

  @impl true
  def verify(blob, sig, cert, opts) when is_list(opts) do
    key = {Keyword.fetch!(opts, :artifact), Keyword.get(opts, :name), Keyword.get(opts, :version)}
    :ets.insert(@table, {{:seen, elem(key, 0)}, sha256(File.read!(blob))})
    _ = File.read!(sig)
    _ = File.read!(cert)

    case :ets.lookup(@table, key) do
      [{_, :ok}] -> :ok
      [] -> {:error, {:verification_denied, key}}
    end
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end

defmodule FermixCore.Plugins.Dist.ProvenanceTest do
  use ExUnit.Case, async: false

  alias FermixCore.Plugins.Dist.Archive
  alias FermixCore.Plugins.Dist.Installer
  alias FermixCore.Plugins.Dist.Provenance
  alias FermixCore.Plugins.Dist.Provenance.Snapshot
  alias FermixCore.Plugins.Dist.ProvenanceVerifierStub, as: VerifierStub
  alias FermixCore.Plugins.Dist.Store
  alias FermixCore.Plugins.Dist.TreeDigest
  alias FermixTestSupport.DistFetcherStub
  alias FermixTestSupport.DistFixtures
  alias FermixTestSupport.SafeRm

  @name "eden"
  @version "1.0.0"

  setup do
    root = SafeRm.make_tmp_dir!("fermix-dist-provenance")
    fixtures = Path.join(root, "fixtures")
    File.mkdir_p!(fixtures)
    Store.ensure!(root)
    VerifierStub.init()
    DistFetcherStub.init()

    on_exit(fn ->
      VerifierStub.cleanup()
      DistFetcherStub.cleanup()
      SafeRm.rm_rf(root)
    end)

    %{root: root, fixtures: fixtures}
  end

  describe "verify/3 happy path" do
    test "returns the snapshot decoded from the verified archive binary", ctx do
      %{sha: sha, digest: digest} = install_remote(ctx)
      allow_publisher()

      assert {:ok, snapshot} = verify(ctx)
      assert snapshot.name == @name
      assert snapshot.version == @version
      assert snapshot.tree_digest == digest
      assert snapshot.artifact_sha256 == sha
      assert Snapshot.paths(snapshot) == ["plugin.json", "skills/#{@name}/SKILL.md"]
      assert {:ok, manifest} = Snapshot.fetch(snapshot, "plugin.json")
      assert Jason.decode!(manifest)["name"] == @name

      # Cosign saw exactly the bytes the gate captured — not a path it reopened.
      assert VerifierStub.seen(:plugin) == sha
    end

    test "an unknown path is not silently empty", ctx do
      install_remote(ctx)
      allow_publisher()

      assert {:ok, snapshot} = verify(ctx)

      assert {:error, {:not_in_snapshot, "src/index.js"}} =
               Snapshot.fetch(snapshot, "src/index.js")
    end

    test "the per-attempt scratch copy is removed on the way out", ctx do
      install_remote(ctx)
      allow_publisher()

      assert {:ok, _snapshot} = verify(ctx)
      assert File.ls!(Store.paths(ctx.root).run) == []
    end
  end

  describe "verify/3 refuses before any manifest, skill, or credential is touched" do
    test "an unsigned dev_local remote root is non-runnable", _ctx do
      assert {:error, :unverified_remote_runtime} = Provenance.verify(:dev_local, @name)
      assert {:error, :unverified_remote_runtime} = Provenance.verify(:bundled, @name)
    end

    test "a plugin with no active version", ctx do
      assert {:error, {:no_active_version, "ghost"}} =
               Provenance.verify({:installed, ctx.root}, "ghost", verifier: VerifierStub)
    end

    test "an evidence path replaced by a symlink is refused, not followed", ctx do
      %{tgz: tgz} = install_remote(ctx)
      allow_publisher()
      archive = evidence_path(ctx, "artifact.tgz")
      SafeRm.rm!(archive)
      File.ln_s!(tgz, archive)

      assert {:error, {:evidence_not_a_file, :archive, :symlink}} = verify(ctx)
    end

    test "a bad publisher signature", ctx do
      install_remote(ctx)

      assert {:error, {:verification_failed, :plugin, {:verification_denied, _}}} = verify(ctx)
    end

    test "a swapped archive no longer matches the published checksum", ctx do
      install_remote(ctx)
      allow_publisher()
      {forged, _forged_sha} = forged_archive(ctx, [{~c"assets/evil.txt", "payload"}])
      File.cp!(forged, evidence_path(ctx, "artifact.tgz"))

      assert {:error, {:artifact_checksum_mismatch, _published, _held}} = verify(ctx)
    end

    test "rewriting every locally editable evidence file still refuses", ctx do
      install_remote(ctx)
      allow_publisher()
      {forged, forged_sha} = forged_archive(ctx, [{~c"assets/evil.txt", "payload"}])
      File.cp!(forged, evidence_path(ctx, "artifact.tgz"))
      File.write!(evidence_path(ctx, "artifact.sha256"), forged_sha)

      # The checksum file now agrees with the swapped archive, so the snapshot
      # decodes — and its digest no longer describes the installed tree.
      assert {:error, {:active_tree_mismatch, _derived, _active}} = verify(ctx)

      # Cosign was handed the forged bytes, so in production the publisher
      # signature is what breaks first: the local files are not the trust root.
      assert VerifierStub.seen(:plugin) == forged_sha
    end

    test "a manifest whose runtime kind is not remote", ctx do
      install_remote(ctx, runtime: %{"kind" => "node", "command" => "server.mjs"})
      allow_publisher()

      assert {:error, {:snapshot_runtime_mismatch, "node"}} = verify(ctx)
    end

    test "an archive carrying the same path twice is an ambiguity, not a last-wins merge", ctx do
      install_remote(ctx, extra_members: [{~c"README.md", "a"}, {~c"README.md", "b"}])
      allow_publisher()

      assert {:error, {:duplicate_snapshot_path, "README.md"}} = verify(ctx)
    end
  end

  describe "verify/3 tamper signals on the active tree" do
    test "a modified active tree refuses", ctx do
      install_remote(ctx)
      allow_publisher()
      File.write!(Path.join(active_dir(ctx), "extra.txt"), "injected")

      assert {:error, {:active_tree_mismatch, _derived, _actual}} = verify(ctx)
    end

    test "a forged install record cannot authorize a tampered tree", ctx do
      # `installed.json` is an evidence *locator*, never the proof: rewriting it
      # to describe the tampered tree changes nothing the gate reads.
      %{sha: sha} = install_remote(ctx)
      allow_publisher()
      File.write!(Path.join(active_dir(ctx), "plugin.json"), ~s({"name":"eden"}))
      {:ok, forged} = TreeDigest.digest_tree(active_dir(ctx))

      :ok =
        Store.record(ctx.root, @name, %{
          "version" => @version,
          "sha256" => sha,
          "tree_digest_v2" => forged
        })

      assert {:error, {:active_tree_mismatch, _derived, ^forged}} = verify(ctx)
    end

    test "an attacker-planted version with no evidence refuses", ctx do
      install_remote(ctx)
      allow_publisher()
      planted = Store.version_dir(ctx.root, @name, "9.9.9")
      File.mkdir_p!(planted)
      File.write!(Path.join(planted, "plugin.json"), ~s({"name":"eden","version":"9.9.9"}))
      :ok = Store.activate(ctx.root, @name, "9.9.9")

      assert {:error, {:evidence_unreadable, :archive, :enoent}} = verify(ctx)
    end

    test "the running generation keeps its bytes; the next start rejects the swap", ctx do
      install_remote(ctx)
      allow_publisher()
      assert {:ok, snapshot} = verify(ctx)
      assert {:ok, original} = Snapshot.fetch(snapshot, "plugin.json")

      # Swap the installed tree AFTER verification but BEFORE any read.
      File.write!(Path.join(active_dir(ctx), "plugin.json"), ~s({"name":"evil"}))

      assert {:ok, ^original} = Snapshot.fetch(snapshot, "plugin.json")
      refute original =~ "evil"
      assert {:error, {:active_tree_mismatch, _derived, _actual}} = verify(ctx)
    end
  end

  describe "a yank is not a kill switch (§9.3)" do
    test "a yank blocks a new install while the verified one keeps loading", ctx do
      %{tgz: tgz, sha: sha} = install_remote(ctx)
      allow_publisher()
      assert {:ok, _snapshot} = verify(ctx)

      plugin =
        DistFixtures.wire(ctx.fixtures, @name, @version, tgz, sha,
          plugin_api: 3,
          yanked: [@version]
        )

      idx = DistFixtures.write_index(Path.join(ctx.fixtures, "index.json"), [plugin])

      assert {:error, {:yanked, @name, @version}} =
               Installer.run_install(@name,
                 root: ctx.root,
                 index_opts: [seed_path: idx],
                 target: "any",
                 core_version: "0.5.0",
                 lock_opts: [attempts: 20, delay_ms: 2]
               )

      # The gate consults no catalog at all, so leaving the shipping index
      # cannot revoke an already-verified install.
      assert {:ok, _snapshot} = verify(ctx)
    end
  end

  describe "retain/4" do
    test "writes the evidence set outside the loadable tree", ctx do
      install_remote(ctx)
      dir = Store.evidence_dir(ctx.root, @name, @version)

      assert Enum.sort(File.ls!(dir)) == [
               "artifact.pem",
               "artifact.sha256",
               "artifact.sig",
               "artifact.tgz"
             ]

      refute File.exists?(Path.join(active_dir(ctx), "artifact.tgz"))
      refute String.starts_with?(dir, Store.paths(ctx.root).installed)
    end

    test "refuses incomplete evidence material", ctx do
      material = Map.delete(full_material(ctx), :cert)

      assert {:error, {:missing_evidence_material, :cert}} =
               Provenance.retain(ctx.root, @name, @version, material)
    end

    test "refuses a checksum that is not a sha256 hex digest", ctx do
      material = Map.put(full_material(ctx), :sha256, "nope")

      assert {:error, {:invalid_artifact_checksum, "nope"}} =
               Provenance.retain(ctx.root, @name, @version, material)
    end
  end

  describe "remote_runtime?/1" do
    test "is the single authority on which plugins the gate covers" do
      assert Provenance.remote_runtime?(%{"kind" => "remote_mcp"})
      refute Provenance.remote_runtime?(%{"kind" => "node", "command" => "server.mjs"})
      refute Provenance.remote_runtime?(nil)
      assert Provenance.remote_kind() == "remote_mcp"
    end
  end

  # --- fixtures ---

  defp verify(ctx), do: Provenance.verify({:installed, ctx.root}, @name, verifier: VerifierStub)

  defp allow_publisher, do: VerifierStub.allow(:plugin, @name, @version)

  defp active_dir(ctx), do: Store.version_dir(ctx.root, @name, @version)

  defp evidence_path(ctx, file),
    do: Path.join(Store.evidence_dir(ctx.root, @name, @version), file)

  # Build a data-only remote artifact, install it into the store the way the
  # installer does, then retain its evidence. Kept independent of
  # `Registry.decode_manifest/2`: the gate runs *before* the manifest is
  # decoded, so it only needs identity and runtime kind out of `plugin.json`.
  defp install_remote(ctx, opts \\ []) do
    {tgz, sha} =
      build_archive(ctx.fixtures,
        runtime: Keyword.get(opts, :runtime, remote_runtime()),
        extra_members: Keyword.get(opts, :extra_members, [])
      )

    staged = Path.join(Store.paths(ctx.root).staging, "#{@name}-#{@version}")
    :ok = Archive.extract(tgz, staged)
    {:ok, digest} = TreeDigest.digest_tree(staged)
    :ok = Store.install_tree(ctx.root, @name, @version, staged)
    :ok = retain(ctx, tgz, sha)
    %{tgz: tgz, sha: sha, digest: digest}
  end

  # A same-identity artifact with different contents, built in its own directory
  # so it never overwrites the installed one's fixture file.
  defp forged_archive(ctx, extra_members) do
    dir = Path.join(ctx.fixtures, "forged")
    File.mkdir_p!(dir)
    build_archive(dir, runtime: remote_runtime(), extra_members: extra_members)
  end

  defp build_archive(dir, opts) do
    DistFixtures.build_tarball(dir, @name, @version,
      manifest_extra: %{"plugin_api" => 3, "runtime" => Keyword.fetch!(opts, :runtime)},
      extra_members: Keyword.fetch!(opts, :extra_members)
    )
  end

  defp remote_runtime do
    %{
      "kind" => "remote_mcp",
      "transport" => "streamable_http",
      "protocol_version" => "2025-06-18",
      "base_url" => "https://mcp.example.com",
      "mcp_path" => "/mcp",
      "tool_name_mode" => "prefix"
    }
  end

  defp retain(ctx, tgz, sha) do
    Provenance.retain(ctx.root, @name, @version, %{
      archive: tgz,
      sig: write(ctx, "artifact.sig", "artifact-signature"),
      cert: write(ctx, "artifact.pem", "artifact-cert"),
      sha256: sha
    })
  end

  defp full_material(ctx) do
    %{
      archive: write(ctx, "artifact.tgz", "tgz"),
      sig: write(ctx, "artifact.sig", "sig"),
      cert: write(ctx, "artifact.pem", "cert"),
      sha256: String.duplicate("a", 64)
    }
  end

  defp write(ctx, name, body) do
    path = Path.join(ctx.fixtures, name)
    File.write!(path, body)
    path
  end
end
