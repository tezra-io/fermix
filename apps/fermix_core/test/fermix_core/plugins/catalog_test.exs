defmodule FermixCore.Plugins.CatalogTest do
  use ExUnit.Case, async: true

  alias FermixCore.Plugins.Catalog
  alias FermixCore.Plugins.Dist.Store
  alias FermixTestSupport.DistFixtures
  alias FermixTestSupport.SafeRm

  @bundled ~w(gmail google_calendar google_drive)
  @core "1.0.0"

  setup do
    root = SafeRm.make_tmp_dir!("fermix-catalog")
    Store.ensure!(root)
    on_exit(fn -> SafeRm.rm_rf(root) end)
    %{root: root}
  end

  defp overview!(root, entries) do
    seed = DistFixtures.write_index(Path.join(root, "fixtures/index.json"), entries)

    assert {:ok, overview} =
             Catalog.overview(root: root, index_opts: [seed_path: seed], core_version: @core)

    overview
  end

  # An index plugin entry shaped like the published catalog (parser-strict).
  defp index_entry(name, opts \\ []) do
    %{
      "name" => name,
      "display_name" => Keyword.get(opts, :display_name, name),
      "description" => "#{name} from the catalog",
      "category" => "developer",
      "auth_type" => Keyword.get(opts, :auth_type, "none"),
      "rails" => Keyword.get(opts, :rails, ["http"]),
      "logo" => Keyword.get(opts, :logo),
      "latest" => Keyword.get(opts, :latest, "1.0.0"),
      "yanked" => Keyword.get(opts, :yanked, []),
      "versions" => Keyword.get(opts, :versions, [version_entry("1.0.0", opts)])
    }
  end

  defp version_entry(version, opts) do
    %{
      "version" => version,
      "published_at" => "2026-06-07T00:00:00Z",
      "min_core_version" => Keyword.get(opts, :min_core_version, "0.1.0"),
      "plugin_api" => Keyword.get(opts, :plugin_api, 2),
      "artifacts" => [
        %{
          "target" => "any",
          "url" => "https://example.com/#{version}.tar.gz",
          "sha256" => String.duplicate("0", 64),
          "sig_url" => "https://example.com/#{version}.sig",
          "cert_url" => "https://example.com/#{version}.pem"
        }
      ]
    }
  end

  # A ready installed plugin: versioned tree + current symlink + lockfile
  # entry, the shape Installer.run_install/2 leaves behind.
  defp install_fixture(root, name, version) do
    dir = Store.version_dir(root, name, version)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "plugin.json"), Jason.encode!(manifest(name, version)))
    :ok = Store.activate(root, name, version)

    :ok =
      Store.record(root, name, %{
        "version" => version,
        "sha256" => String.duplicate("0", 64),
        "h1" => String.duplicate("0", 64),
        "plugin_api" => 2,
        "min_core_version" => "0.1.0"
      })
  end

  defp manifest(name, version) do
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
      "skills" => []
    }
  end

  describe "overview/1 union" do
    test "index-only plugins surface as available alongside registry plugins", %{root: root} do
      logo = %{"mime" => "image/png", "data_base64" => Base.encode64("png-bytes")}
      overview = overview!(root, [index_entry("hackernews", logo: logo)])

      assert Enum.map(overview.installed, & &1.name) == @bundled
      assert [entry] = overview.available
      assert entry.name == "hackernews"
      assert entry.display_name == "hackernews"
      assert entry.description == "hackernews from the catalog"
      assert entry.auth_type == :none
      assert entry.rails == ["http"]
      assert entry.logo == logo
      assert entry.latest == "1.0.0"
      assert entry.compat == :ok
      assert overview.yanked_installed == %{}
      assert overview.index_error == nil
    end

    test "installed and bundled names are not repeated as available", %{root: root} do
      install_fixture(root, "demo", "1.0.0")

      entries = [index_entry("demo"), index_entry("gmail"), index_entry("hackernews")]
      overview = overview!(root, entries)

      assert Enum.map(overview.available, & &1.name) == ["hackernews"]
      assert "demo" in Enum.map(overview.installed, & &1.name)
    end

    test "an incompatible latest is surfaced greyed, not hidden", %{root: root} do
      entries = [
        index_entry("needs_core", min_core_version: "9.9.9"),
        index_entry("needs_api", plugin_api: 99)
      ]

      overview = overview!(root, entries)

      assert %{compat: {:error, {:needs_newer_core, :min_core_version, "9.9.9"}}} =
               Enum.find(overview.available, &(&1.name == "needs_core"))

      assert %{compat: {:error, {:needs_newer_core, :plugin_api, 99}}} =
               Enum.find(overview.available, &(&1.name == "needs_api"))
    end

    test "a yanked or absent latest version is a compat error", %{root: root} do
      entries = [
        index_entry("pulled", yanked: ["1.0.0"]),
        index_entry("hollow", versions: [])
      ]

      overview = overview!(root, entries)

      assert %{compat: {:error, {:yanked, "pulled", "1.0.0"}}} =
               Enum.find(overview.available, &(&1.name == "pulled"))

      assert %{compat: {:error, {:version_not_found, "hollow", "1.0.0"}}} =
               Enum.find(overview.available, &(&1.name == "hollow"))
    end

    test "an installed yanked version is flagged loud", %{root: root} do
      install_fixture(root, "demo", "1.0.0")
      overview = overview!(root, [index_entry("demo", yanked: ["1.0.0"], latest: "1.1.0")])

      assert overview.yanked_installed == %{"demo" => "1.0.0"}
      refute Enum.any?(overview.available, &(&1.name == "demo"))
    end

    test "an unreadable index degrades to installed-only with the error surfaced", %{root: root} do
      missing = Path.join(root, "nope")

      assert {:ok, overview} =
               Catalog.overview(
                 root: root,
                 index_opts: [seed_path: missing],
                 core_version: @core
               )

      assert Enum.map(overview.installed, & &1.name) == @bundled
      assert overview.available == []
      assert overview.yanked_installed == %{}
      assert overview.index_error == :enoent
    end
  end
end
