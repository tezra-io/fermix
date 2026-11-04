defmodule FermixCore.Home.Archive.ManifestTest do
  use ExUnit.Case, async: true

  alias FermixCore.BuildInfo
  alias FermixCore.Home.Archive.Manifest

  @sha String.duplicate("ab", 32)

  test "a manifest encodes to the documented JSON and decodes back" do
    files = [%{path: "config.toml", bytes: 12, sha256: @sha, mode: 0o600}]
    links = [%{path: "plugins/installed/notes/current", target: "1.0.0"}]
    header = %{primary_epoch: 4, home_root: "/home/invented/.fermix", host: "macos-aarch64"}
    manifest = Manifest.new(header, files, links)
    json = Manifest.encode(manifest)

    assert %{
             "format" => 1,
             "created_at" => created_at,
             "primary_epoch" => 4,
             "engine_version" => version,
             "home_root" => "/home/invented/.fermix",
             "host" => "macos-aarch64",
             "files" => [
               %{"path" => "config.toml", "bytes" => 12, "sha256" => @sha, "mode" => 384}
             ],
             "links" => [%{"path" => "plugins/installed/notes/current", "target" => "1.0.0"}]
           } = Jason.decode!(json)

    assert {:ok, _at, 0} = DateTime.from_iso8601(created_at)
    assert version == BuildInfo.product_version()
    assert Manifest.decode(json) == {:ok, manifest}
  end

  test "a format this build does not read is refused by name" do
    assert Manifest.decode(json(%{"format" => 2})) == {:error, {:unsupported_format, 2}}
  end

  test "a manifest of the wrong shape is invalid, entry by entry" do
    for bad <- [
          %{"primary_epoch" => 0},
          %{"primary_epoch" => "3"},
          %{"created_at" => "yesterday"},
          %{"engine_version" => nil},
          %{"home_root" => nil},
          %{"home_root" => "relative/home"},
          %{"home_root" => "/home/invented/../escape"},
          %{"host" => nil},
          %{"host" => "macOS arm64"},
          %{"files" => [%{"path" => "a", "bytes" => -1, "sha256" => @sha, "mode" => 0o600}]},
          %{"files" => [%{"path" => "a", "bytes" => 1, "sha256" => "AB", "mode" => 0o600}]},
          %{"files" => [%{"path" => "a", "bytes" => 1, "sha256" => @sha, "mode" => 0o4755}]},
          %{"files" => [%{"path" => "a", "bytes" => 1, "sha256" => @sha}]},
          %{"files" => "config.toml"},
          %{"links" => nil},
          %{"links" => [%{"path" => "a"}]}
        ] do
      assert {:error, {:invalid_manifest, _detail}} = Manifest.decode(json(bad)), inspect(bad)
    end

    assert {:error, {:invalid_manifest, _detail}} = Manifest.decode("not json")
    assert {:error, {:invalid_manifest, _detail}} = Manifest.decode("[]")
  end

  test "a path that could leave the root is refused by name" do
    for path <- [
          "../escape",
          "/etc/passwd",
          "memory/../../escape",
          "a//b",
          "./a",
          "a/",
          "",
          "nul\0byte"
        ] do
      files = [%{"path" => path, "bytes" => 1, "sha256" => @sha, "mode" => 0o600}]
      assert Manifest.decode(json(%{"files" => files})) == {:error, {:unsafe_path, path}}
    end
  end

  test "a device-local path is refused, so a restore can never write one" do
    for path <- ["moved.json", "logs/fermix.log", "daemon.sock"] do
      files = [%{"path" => path, "bytes" => 1, "sha256" => @sha, "mode" => 0o600}]
      assert Manifest.decode(json(%{"files" => files})) == {:error, {:device_local_entry, path}}
    end
  end

  test "a link must stay inside the root and nothing may lie beneath one" do
    for {path, target} <- [
          {"current", "/etc"},
          {"current", "../outside"},
          {"plugins/current", "../../outside"},
          {"a/up", "x/../.."},
          {"a/up", "x/.."},
          {"a/up", ""},
          {"a/up", "x/"}
        ] do
      links = [%{"path" => path, "target" => target}]

      assert Manifest.decode(json(%{"links" => links})) ==
               {:error, {:unsafe_link, path, target}},
             inspect({path, target})
    end

    for {path, target} <- [{"a/b/current", "1.0.0"}, {"a/b/bin", "../../lib/run"}, {"a/up", ".."}] do
      assert Manifest.safe_link?(path, target), inspect({path, target})
    end

    file = %{"path" => "dir/inside", "bytes" => 1, "sha256" => @sha, "mode" => 0o600}
    link = %{"path" => "dir", "target" => "elsewhere"}

    assert Manifest.decode(json(%{"files" => [file], "links" => [link]})) ==
             {:error, {:unsafe_link, "dir", "elsewhere"}}
  end

  test "one path twice is invalid" do
    entry = %{"path" => "config.toml", "bytes" => 1, "sha256" => @sha, "mode" => 0o600}

    assert Manifest.decode(json(%{"files" => [entry, entry]})) ==
             {:error, {:invalid_manifest, {:duplicate_path, "config.toml"}}}

    link = %{"path" => "config.toml", "target" => "elsewhere"}

    assert Manifest.decode(json(%{"files" => [entry], "links" => [link]})) ==
             {:error, {:invalid_manifest, {:duplicate_path, "config.toml"}}}
  end

  test "the file count and the byte total are bounded by name" do
    max_files = Manifest.max_files()
    max_bytes = Manifest.max_total_bytes()

    too_many =
      for n <- 0..max_files,
          do: %{"path" => "f#{n}", "bytes" => 0, "sha256" => @sha, "mode" => 0o600}

    assert Manifest.decode(json(%{"files" => too_many})) ==
             {:error, {:too_many_files, max_files + 1, max_files}}

    too_big = [
      %{"path" => "a", "bytes" => max_bytes, "sha256" => @sha, "mode" => 0o600},
      %{"path" => "b", "bytes" => 1, "sha256" => @sha, "mode" => 0o600}
    ]

    assert Manifest.decode(json(%{"files" => too_big})) ==
             {:error, {:too_many_bytes, max_bytes + 1, max_bytes}}

    assert Manifest.check_bounds(1, max_bytes) == :ok

    assert Manifest.check_bounds(max_files + 1, 0) ==
             {:error, {:too_many_files, max_files + 1, max_files}}
  end

  defp json(overrides) do
    %{
      "format" => 1,
      "created_at" => "2026-10-27T09:30:00Z",
      "primary_epoch" => 3,
      "engine_version" => "0.0.0",
      "home_root" => "/home/invented/.fermix",
      "host" => "macos-aarch64",
      "files" => [],
      "links" => []
    }
    |> Map.merge(overrides)
    |> Jason.encode!()
  end
end
