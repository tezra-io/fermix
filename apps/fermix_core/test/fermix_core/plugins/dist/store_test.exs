defmodule FermixCore.Plugins.Dist.StoreTest do
  use ExUnit.Case, async: true

  alias FermixCore.Plugins.Dist.Store

  setup do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("fermix-dist-store")
    Store.ensure!(root)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(root) end)
    %{root: root}
  end

  # Build a staged plugin tree ready for install_tree/4.
  defp stage(root, name, version, files \\ %{"plugin.json" => "{}"}) do
    dir = Path.join([Store.paths(root).staging, "#{name}-#{version}"])

    Enum.each(files, fn {rel, content} ->
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end)

    dir
  end

  describe "installed.json lockfile" do
    test "record, read, and forget round-trip", %{root: root} do
      assert Store.installed(root) == %{}
      assert :ok = Store.record(root, "github", %{"version" => "1.2.0", "plugin_api" => 2})
      assert %{"github" => %{"version" => "1.2.0"}} = Store.installed(root)
      assert :ok = Store.forget(root, "github")
      assert Store.installed(root) == %{}
    end

    test "an absent lockfile reads as empty (valid 'nothing installed' state)", %{root: root} do
      assert Store.installed(root) == %{}
    end

    test "a corrupt lockfile raises loud — never silently erases installed plugins", %{root: root} do
      File.write!(Store.paths(root).lockfile, "{ not json")

      assert_raise RuntimeError, ~r/corrupt plugin lockfile/, fn -> Store.installed(root) end

      # record/2 also refuses rather than overwriting the corrupt file with a
      # fresh single-entry one (which would drop every other plugin's record).
      assert_raise RuntimeError, ~r/corrupt plugin lockfile/, fn ->
        Store.record(root, "github", %{"version" => "1.0.0"})
      end
    end
  end

  describe "install_tree/4 and active_version/2" do
    test "renames staging into the version dir and flips current", %{root: root} do
      staged = stage(root, "github", "1.2.0", %{"plugin.json" => ~s({"name":"github"})})
      assert :ok = Store.install_tree(root, "github", "1.2.0", staged)

      assert Store.active_version(root, "github") == "1.2.0"

      assert File.read!(Path.join(Store.version_dir(root, "github", "1.2.0"), "plugin.json")) =~
               "github"

      refute File.exists?(staged), "staging dir is consumed by the rename"
    end

    test "activate flips current between installed versions", %{root: root} do
      Store.install_tree(root, "github", "1.0.0", stage(root, "github", "1.0.0"))
      Store.install_tree(root, "github", "1.2.0", stage(root, "github", "1.2.0"))
      assert Store.active_version(root, "github") == "1.2.0"

      assert :ok = Store.activate(root, "github", "1.0.0")
      assert Store.active_version(root, "github") == "1.0.0"
    end

    test "active_version is nil for an unknown plugin", %{root: root} do
      assert Store.active_version(root, "nope") == nil
    end
  end

  describe "h1/1" do
    test "is deterministic and content-addressed", %{root: root} do
      a = stage(root, "a", "1", %{"plugin.json" => "X", "skills/s/SKILL.md" => "Y"})
      b = stage(root, "b", "1", %{"plugin.json" => "X", "skills/s/SKILL.md" => "Y"})
      c = stage(root, "c", "1", %{"plugin.json" => "X", "skills/s/SKILL.md" => "DIFFERENT"})

      assert Store.h1(a) == Store.h1(b)
      assert Store.h1(a) != Store.h1(c)
    end
  end

  describe "compatible?/2 (§13)" do
    test "the window is exactly one generation of back-compat" do
      assert Store.supported_plugin_api() == 3
    end

    test "accepts a version inside the support window" do
      assert :ok = Store.compatible?(%{plugin_api: 3, min_core_version: "0.1.0"}, "0.5.0")
      assert :ok = Store.compatible?(%{"plugin_api" => 2, "min_core_version" => nil}, "0.5.0")
    end

    test "refuses a plugin_api newer than core supports" do
      assert {:error, {:needs_newer_core, :plugin_api, 4}} =
               Store.compatible?(%{plugin_api: 4}, "0.5.0")
    end

    test "refuses a plugin_api below the one-generation window" do
      assert {:error, {:plugin_too_old, :plugin_api, 1}} =
               Store.compatible?(%{plugin_api: 1}, "0.5.0")
    end

    test "refuses when core is below min_core_version" do
      assert {:error, {:needs_newer_core, :min_core_version, "0.6.0"}} =
               Store.compatible?(%{plugin_api: 2, min_core_version: "0.6.0"}, "0.4.0")
    end

    test "refuses a missing plugin_api" do
      assert {:error, :missing_plugin_api} =
               Store.compatible?(%{min_core_version: "0.1.0"}, "0.5.0")
    end
  end

  describe "list/2" do
    test "marks installed plugins ready or incompatible against the running core", %{root: root} do
      Store.install_tree(root, "github", "1.2.0", stage(root, "github", "1.2.0"))

      Store.record(root, "github", %{
        "version" => "1.2.0",
        "plugin_api" => 2,
        "min_core_version" => "0.1.0"
      })

      Store.install_tree(root, "old", "1.0.0", stage(root, "old", "1.0.0"))

      Store.record(root, "old", %{
        "version" => "1.0.0",
        "plugin_api" => 2,
        "min_core_version" => "9.9.9"
      })

      assert [%{name: "github", status: :ready}, %{name: "old", status: :incompatible}] =
               Store.list(root, "0.5.0")
    end

    test "a pre-M27 entry with no tree_digest_v2 keeps loading", %{root: root} do
      # `tree_digest_v2` is written for every new install, but entries recorded
      # before it existed carry only `h1` and are never migrated in place —
      # they must not become `:incompatible` on upgrade.
      Store.install_tree(root, "legacy", "1.0.0", stage(root, "legacy", "1.0.0"))

      Store.record(root, "legacy", %{
        "version" => "1.0.0",
        "sha256" => String.duplicate("a", 64),
        "h1" => String.duplicate("b", 64),
        "plugin_api" => 2,
        "min_core_version" => "0.1.0"
      })

      assert [%{name: "legacy", version: "1.0.0", status: :ready}] = Store.list(root, "0.5.0")
      refute Map.has_key?(Map.fetch!(Store.installed(root), "legacy"), "tree_digest_v2")
    end
  end

  describe "uninstall/2" do
    test "removes the tree, the lockfile entry, and legacy seeded skills", %{root: root} do
      Store.install_tree(root, "github", "1.2.0", stage(root, "github", "1.2.0"))
      Store.record(root, "github", %{"version" => "1.2.0"})
      legacy = Path.join([root, "github", "skills", "github"])
      File.mkdir_p!(legacy)

      assert :ok = Store.uninstall(root, "github")
      refute File.exists?(Path.join(Store.paths(root).installed, "github"))
      refute File.exists?(Path.join(root, "github"))
      assert Store.installed(root) == %{}
    end

    test "removes the version's provenance evidence with it (§9.3)", %{root: root} do
      Store.install_tree(root, "eden", "1.0.0", stage(root, "eden", "1.0.0"))
      stage_evidence(root, "eden", "1.0.0")

      assert :ok = Store.uninstall(root, "eden")
      refute File.exists?(Store.evidence_dir(root, "eden", "1.0.0"))
      refute File.exists?(Path.join(Store.paths(root).evidence, "eden"))
    end
  end

  describe "gc/1" do
    test "keeps the active version and the one-deep rollback, removes the rest", %{root: root} do
      for v <- ["1.0.0", "1.1.0", "1.2.0"] do
        Store.install_tree(root, "github", v, stage(root, "github", v))
      end

      # current is 1.2.0 (last installed); rollback = newest non-active = 1.1.0
      File.mkdir_p!(Path.join(Store.paths(root).staging, "leftover"))
      assert :ok = Store.gc(root)

      assert File.exists?(Store.version_dir(root, "github", "1.2.0"))
      assert File.exists?(Store.version_dir(root, "github", "1.1.0"))
      refute File.exists?(Store.version_dir(root, "github", "1.0.0"))
      assert File.ls!(Store.paths(root).staging) == []
    end

    test "evidence is collected with its version and never separated from it", %{root: root} do
      for v <- ["1.0.0", "1.1.0", "1.2.0"] do
        Store.install_tree(root, "eden", v, stage(root, "eden", v))
        stage_evidence(root, "eden", v)
      end

      assert :ok = Store.gc(root)

      # active (1.2.0) and the one-deep rollback (1.1.0) keep theirs — rollback
      # re-verifies, so evidence has to still be there.
      assert File.exists?(Store.evidence_dir(root, "eden", "1.2.0"))
      assert File.exists?(Store.evidence_dir(root, "eden", "1.1.0"))
      refute File.exists?(Store.evidence_dir(root, "eden", "1.0.0"))
    end

    test "evidence for a name that is no longer installed is collected", %{root: root} do
      stage_evidence(root, "ghost", "9.9.9")
      refute File.dir?(Path.join(Store.paths(root).installed, "ghost"))

      assert :ok = Store.gc(root)
      refute File.exists?(Path.join(Store.paths(root).evidence, "ghost"))
    end
  end

  describe "sweep_transient!/1" do
    test "clears staging dirs and run/*.token but keeps other run files", %{root: root} do
      File.mkdir_p!(Path.join(Store.paths(root).staging, "half-download"))
      File.write!(Path.join(Store.paths(root).run, "gmail.token"), "secret")
      File.write!(Path.join(Store.paths(root).run, "keep.txt"), "ok")

      assert :ok = Store.sweep_transient!(root)
      assert File.ls!(Store.paths(root).staging) == []
      refute File.exists?(Path.join(Store.paths(root).run, "gmail.token"))
      assert File.exists?(Path.join(Store.paths(root).run, "keep.txt"))
    end

    test "clears a provenance scratch dir left by a crashed verify", %{root: root} do
      scratch = Store.transient_run_dir(root, "1234-1")
      File.mkdir_p!(scratch)
      File.write!(Path.join(scratch, "plugin.blob"), "a whole artifact")

      assert :ok = Store.sweep_transient!(root)
      refute File.exists?(scratch)
    end
  end

  # Evidence stand-in: `gc/1` and `uninstall/2` care only that the directory for
  # a version exists, not what a real evidence set contains.
  defp stage_evidence(root, name, version) do
    dir = Store.evidence_dir(root, name, version)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "artifact.tgz"), "artifact")
    dir
  end
end
