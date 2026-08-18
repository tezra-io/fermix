defmodule FermixCore.ComputerHistory.InstalledAppsTest do
  @moduledoc "MILESTONE_32 §22.7 — the setup app-allowlist picker's installed-app enumerator."
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.InstalledApps

  defp make_app(dir, name) do
    app = Path.join(dir, name <> ".app")
    File.mkdir_p!(Path.join(app, "Contents"))
    app
  end

  describe "list/1 (injected reader — hermetic, cross-platform)" do
    setup do
      dir = FermixTestSupport.SafeRm.make_tmp_dir!("installed-apps")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(dir) end)
      %{dir: dir}
    end

    test "walks .app bundles, maps to bundle ids, sorts by name case-insensitively", %{dir: dir} do
      make_app(dir, "Safari")
      make_app(dir, "notes")
      make_app(dir, "Mail")

      bundles = %{
        "Safari" => "com.apple.Safari",
        "notes" => "com.apple.Notes",
        "Mail" => "com.apple.mail"
      }

      reader = fn path -> Map.get(bundles, Path.basename(path, ".app")) end
      apps = InstalledApps.list(macos?: true, dirs: [dir], bundle_id_reader: reader)

      assert Enum.map(apps, & &1.name) == ["Mail", "notes", "Safari"]

      assert Enum.map(apps, & &1.bundle_id) == [
               "com.apple.mail",
               "com.apple.Notes",
               "com.apple.Safari"
             ]
    end

    test "skips a bundle whose id can't be read (nil), never fails the list", %{dir: dir} do
      make_app(dir, "Good")
      make_app(dir, "Broken")

      reader = fn path ->
        if Path.basename(path, ".app") == "Good", do: "com.x.good", else: nil
      end

      assert InstalledApps.list(macos?: true, dirs: [dir], bundle_id_reader: reader) ==
               [%{name: "Good", bundle_id: "com.x.good"}]
    end

    test "dedupes by bundle id across directories", %{dir: dir} do
      other = FermixTestSupport.SafeRm.make_tmp_dir!("installed-apps-2")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(other) end)
      make_app(dir, "Safari")
      make_app(other, "Safari")

      assert InstalledApps.list(
               macos?: true,
               dirs: [dir, other],
               bundle_id_reader: fn _ -> "com.apple.Safari" end
             ) ==
               [%{name: "Safari", bundle_id: "com.apple.Safari"}]
    end

    test "descends one level into vendor subfolders (e.g. /Applications/Adobe/*.app)", %{dir: dir} do
      make_app(Path.join(dir, "Adobe"), "Photoshop")
      make_app(dir, "Safari")
      reader = fn path -> "com." <> String.downcase(Path.basename(path, ".app")) end

      apps = InstalledApps.list(macos?: true, dirs: [dir], bundle_id_reader: reader)

      assert Enum.map(apps, & &1.name) == ["Photoshop", "Safari"]
      assert "com.photoshop" in Enum.map(apps, & &1.bundle_id)
    end

    test "a missing directory is skipped, not fatal", %{dir: dir} do
      make_app(dir, "Safari")

      assert InstalledApps.list(
               macos?: true,
               dirs: [dir, "/no/such/dir"],
               bundle_id_reader: fn _ -> "com.apple.Safari" end
             ) ==
               [%{name: "Safari", bundle_id: "com.apple.Safari"}]
    end

    test "returns [] off macOS even with a scannable dir (the platform gate short-circuits)", %{
      dir: dir
    } do
      make_app(dir, "Safari")

      assert InstalledApps.list(
               macos?: false,
               dirs: [dir],
               bundle_id_reader: fn _ -> "com.apple.Safari" end
             ) ==
               []
    end
  end

  # The real plutil reader path, exercised only where plutil exists.
  if :os.type() == {:unix, :darwin} do
    test "the default reader extracts CFBundleIdentifier from a real Info.plist" do
      dir = FermixTestSupport.SafeRm.make_tmp_dir!("installed-apps-real")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(dir) end)
      app = make_app(dir, "Fixture")

      File.write!(Path.join([app, "Contents", "Info.plist"]), plist_xml("io.tezra.fixture"))

      assert InstalledApps.list(macos?: true, dirs: [dir]) ==
               [%{name: "Fixture", bundle_id: "io.tezra.fixture"}]
    end

    defp plist_xml(bundle_id) do
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
      <key>CFBundleIdentifier</key><string>#{bundle_id}</string>
      </dict></plist>
      """
    end
  end
end
