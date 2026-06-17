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
    test "accepts a version inside the support window" do
      assert :ok = Store.compatible?(%{plugin_api: 2, min_core_version: "0.1.0"}, "0.5.0")
      assert :ok = Store.compatible?(%{"plugin_api" => 1, "min_core_version" => nil}, "0.5.0")
    end

    test "refuses a plugin_api newer than core supports" do
      assert {:error, {:needs_newer_core, :plugin_api, 3}} =
               Store.compatible?(%{plugin_api: 3}, "0.5.0")
    end

    test "refuses a plugin_api below the one-generation window" do
      assert {:error, {:plugin_too_old, :plugin_api, 0}} =
               Store.compatible?(%{plugin_api: 0}, "0.5.0")
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
  end
end
