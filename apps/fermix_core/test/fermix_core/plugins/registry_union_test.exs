defmodule FermixCore.Plugins.RegistryUnionTest do
  # async: false — the skills test swaps FERMIX_HOME and the :plugins app env.
  use ExUnit.Case, async: false

  alias FermixCore.Plugins.Dist.Store
  alias FermixCore.Plugins.Registry

  @bundled ~w(gmail google_calendar google_drive)

  setup do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("fermix-registry-union")
    Store.ensure!(root)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(root) end)
    %{root: root}
  end

  # Lay down a ready installed plugin: versioned tree + current symlink +
  # lockfile entry, the exact shape Installer.run_install/2 leaves behind.
  defp install_fixture(root, name, opts \\ []) do
    version = Keyword.get(opts, :version, "1.0.0")
    skills = Keyword.get(opts, :skills, [])
    dir = Store.version_dir(root, name, version)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "plugin.json"), Jason.encode!(manifest(name, version, skills)))
    Enum.each(skills, fn %{"path" => path} -> write_skill(dir, path) end)
    :ok = Store.activate(root, name, version)

    :ok =
      Store.record(root, name, %{
        "version" => version,
        "sha256" => String.duplicate("0", 64),
        "h1" => String.duplicate("0", 64),
        "plugin_api" => Keyword.get(opts, :plugin_api, 2),
        "min_core_version" => "0.1.0"
      })
  end

  defp manifest(name, version, skills) do
    %{
      "schema_version" => 2,
      "name" => name,
      "display_name" => name,
      "description" => "Test installed plugin",
      "category" => "developer",
      "version" => version,
      "min_core_version" => "0.1.0",
      "plugin_api" => 2,
      "auth" => %{"type" => "none"},
      "tools" => [],
      "skills" => skills
    }
  end

  defp write_skill(dir, path) do
    skill_dir = Path.join(dir, path)
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), "---\nname: demo\n---\n")
  end

  # A dev_local root is a directory whose immediate subdirectories are plugin
  # dirs — the shape of a fermix-plugins checkout's plugins/ directory.
  defp dev_local_root do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("fermix-registry-dev-local")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(root) end)
    root
  end

  defp dev_local_plugin(root, name, opts \\ []) do
    skills = Keyword.get(opts, :skills, [])
    manifest = Keyword.get(opts, :manifest, manifest(name, "0.0.1", skills))
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "plugin.json"), Jason.encode!(manifest))
    Enum.each(skills, fn %{"path" => path} -> write_skill(dir, path) end)
    dir
  end

  describe "list/1 union" do
    test "installed plugins appear alongside bundled ones", %{root: root} do
      install_fixture(root, "demo")

      assert {:ok, plugins} = Registry.list(installed_root: root)
      names = Enum.map(plugins, & &1.name)
      assert names == Enum.sort(["demo" | @bundled])

      demo = Enum.find(plugins, &(&1.name == "demo"))
      assert demo.path == Path.join([root, "installed", "demo", "current", "plugin.json"])
    end

    test "an empty store changes nothing", %{root: root} do
      assert {:ok, plugins} = Registry.list(installed_root: root)
      assert Enum.map(plugins, & &1.name) == @bundled
    end

    test "an installed plugin shadowing a bundled name fails loud", %{root: root} do
      install_fixture(root, "gmail")

      assert {:error, {:duplicate_plugin_name, "gmail"}} = Registry.list(installed_root: root)
    end

    test "an incompatible installed plugin is excluded, not fatal", %{root: root} do
      install_fixture(root, "demo", plugin_api: 99)

      assert {:ok, plugins} = Registry.list(installed_root: root)
      assert Enum.map(plugins, & &1.name) == @bundled
    end

    test "a ready lockfile entry with an unreadable manifest fails loud", %{root: root} do
      install_fixture(root, "demo")

      FermixTestSupport.SafeRm.rm!(
        Path.join([root, "installed", "demo", "current", "plugin.json"])
      )

      assert {:error, {:installed_manifest_unreadable, _path, :enoent}} =
               Registry.list(installed_root: root)
    end
  end

  describe "list/1 dev_local" do
    test "dev_local plugins appear alongside bundled ones", %{root: root} do
      dev = dev_local_root()
      dev_local_plugin(dev, "devplug")

      assert {:ok, plugins} = Registry.list(installed_root: root, dev_local: dev)
      names = Enum.map(plugins, & &1.name)
      assert names == Enum.sort(["devplug" | @bundled])

      devplug = Enum.find(plugins, &(&1.name == "devplug"))
      assert devplug.path == Path.join([dev, "devplug", "plugin.json"])
    end

    test "the dev_local path resolves from the :plugins app env", %{root: root} do
      dev = dev_local_root()
      dev_local_plugin(dev, "devplug")
      previous = Application.get_env(:fermix_core, :plugins)
      Application.put_env(:fermix_core, :plugins, dev_local: dev)
      on_exit(fn -> restore_app_env(:plugins, previous) end)

      assert {:ok, plugins} = Registry.list(installed_root: root)
      assert "devplug" in Enum.map(plugins, & &1.name)
    end

    test "a dev_local name shadowing a bundled plugin fails loud", %{root: root} do
      dev = dev_local_root()
      dev_local_plugin(dev, "gmail")

      assert {:error, {:duplicate_plugin_name, "gmail"}} =
               Registry.list(installed_root: root, dev_local: dev)
    end

    test "a dev_local name shadowing an installed plugin fails loud", %{root: root} do
      install_fixture(root, "demo")
      dev = dev_local_root()
      dev_local_plugin(dev, "demo")

      assert {:error, {:duplicate_plugin_name, "demo"}} =
               Registry.list(installed_root: root, dev_local: dev)
    end

    test "a configured dev_local path that does not exist fails loud", %{root: root} do
      missing =
        Path.join(
          System.tmp_dir!(),
          "fermix-dev-local-missing-#{System.unique_integer([:positive])}"
        )

      assert {:error, {:dev_local_unreadable, ^missing, :enoent}} =
               Registry.list(installed_root: root, dev_local: missing)
    end

    test "a bad dev_local manifest fails loud, not skipped", %{root: root} do
      dev = dev_local_root()
      broken = manifest("broken", "0.0.1", []) |> Map.put("auth", %{"type" => "bogus"})
      dev_local_plugin(dev, "broken", manifest: broken)

      assert {:error, {:invalid_auth_type, "bogus"}} =
               Registry.list(installed_root: root, dev_local: dev)
    end

    test "entries without a plugin.json are not plugin dirs", %{root: root} do
      dev = dev_local_root()
      File.write!(Path.join(dev, "README.md"), "not a plugin\n")
      File.mkdir_p!(Path.join(dev, "no_manifest"))

      assert {:ok, plugins} = Registry.list(installed_root: root, dev_local: dev)
      assert Enum.map(plugins, & &1.name) == @bundled
    end
  end

  describe "enabled_skill_dirs/1 for dev_local plugins" do
    setup %{root: root} do
      home = FermixTestSupport.SafeRm.make_tmp_dir!("fermix-registry-dev-local-home")
      previous_home = System.get_env("FERMIX_HOME")
      previous_plugins = Application.get_env(:fermix_core, :plugins)
      System.put_env("FERMIX_HOME", home)
      Application.put_env(:fermix_core, :plugins, enabled: ["devplug"])

      on_exit(fn ->
        restore_env("FERMIX_HOME", previous_home)
        restore_app_env(:plugins, previous_plugins)
        FermixTestSupport.SafeRm.rm_rf(home)
      end)

      %{root: root, home: home}
    end

    test "skills load in place from the checkout — no copy-seed", %{root: root, home: home} do
      dev = dev_local_root()
      skills = [%{"name" => "dev_helper", "path" => "skills/dev_helper"}]
      dev_local_plugin(dev, "devplug", skills: skills)

      dirs = Registry.enabled_skill_dirs(installed_root: root, dev_local: dev)

      assert dirs == [Path.join([dev, "devplug", "skills"])]
      refute File.dir?(Path.join([home, "plugins", "devplug", "skills"]))
    end
  end

  describe "enabled_skill_dirs/1 for installed plugins" do
    setup %{root: root} do
      home = FermixTestSupport.SafeRm.make_tmp_dir!("fermix-registry-union-home")
      previous_home = System.get_env("FERMIX_HOME")
      previous_plugins = Application.get_env(:fermix_core, :plugins)
      System.put_env("FERMIX_HOME", home)
      Application.put_env(:fermix_core, :plugins, enabled: ["demo"])

      on_exit(fn ->
        restore_env("FERMIX_HOME", previous_home)
        restore_app_env(:plugins, previous_plugins)
        FermixTestSupport.SafeRm.rm_rf(home)
      end)

      %{root: root, home: home}
    end

    test "skills load in place from current/skills — no copy-seed", %{root: root, home: home} do
      skills = [%{"name" => "demo_helper", "path" => "skills/demo_helper"}]
      install_fixture(root, "demo", skills: skills)

      dirs = Registry.enabled_skill_dirs(installed_root: root)

      assert dirs == [Path.join([root, "installed", "demo", "current", "skills"])]
      refute File.dir?(Path.join([home, "plugins", "demo", "skills"]))
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore_app_env(key, value), do: Application.put_env(:fermix_core, key, value)
end
