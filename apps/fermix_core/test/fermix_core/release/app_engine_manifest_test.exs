defmodule FermixCore.Release.AppEngineManifestTest do
  use ExUnit.Case, async: true

  alias FermixCore.Release.AppEngineManifest
  alias FermixCore.Release.ExecutableInventory

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "fermix-app-engine-manifest-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(root, "bin"))
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "data"))

    File.write!(Path.join(root, "bin/fermix_app_engine"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(root, "bin/fermix_app_engine"), 0o755)
    File.write!(Path.join(root, "lib/fermix_nif.so"), "fake-mach-o")
    File.chmod!(Path.join(root, "lib/fermix_nif.so"), 0o644)
    File.write!(Path.join(root, "data/runtime.txt"), "runtime-data")
    File.ln_s!("fermix_app_engine", Path.join(root, "bin/current"))

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(root) end)
    %{root: root}
  end

  test "builds deterministic identity, protocol, provenance, digest, and inventory metadata", %{
    root: root
  } do
    assert {:ok, manifest} = AppEngineManifest.build(root, opts())

    assert manifest["schema_version"] == 1
    assert manifest["identity"] == public_identity()
    assert manifest["protocols"] == public_protocols()

    assert manifest["provenance"] == %{
             "certificate_identity" =>
               "https://github.com/tezra-io/fermix/.github/workflows/release.yml@refs/tags/v1.2.3",
             "oidc_issuer" => "https://token.actions.githubusercontent.com"
           }

    assert manifest["tree_sha256"] =~ ~r/^[0-9a-f]{64}$/

    assert manifest["inventory"]["artifact_target"] == "macos_aarch64"
    assert manifest["inventory"]["architecture"] == "arm64"

    assert Enum.map(manifest["inventory"]["entries"], & &1["path"]) == [
             "bin/current",
             "bin/fermix_app_engine",
             "lib/fermix_nif.so"
           ]

    assert Enum.find(manifest["inventory"]["entries"], &(&1["path"] == "bin/current")) ==
             %{
               "kind" => "symlink",
               "mode" => "0777",
               "path" => "bin/current",
               "target" => "fermix_app_engine"
             }

    native = Enum.find(manifest["inventory"]["entries"], &(&1["path"] == "lib/fermix_nif.so"))
    assert native["kind"] == "mach_o"
    assert native["architectures"] == ["arm64"]
    assert native["sha256"] =~ ~r/^[0-9a-f]{64}$/
  end

  test "the complete-tree digest changes when a non-executable runtime file changes", %{
    root: root
  } do
    assert {:ok, before} = AppEngineManifest.build(root, opts())

    File.write!(Path.join(root, "data/runtime.txt"), "changed-runtime-data")

    assert {:ok, after_change} = AppEngineManifest.build(root, opts())
    refute after_change["tree_sha256"] == before["tree_sha256"]
  end

  test "the complete-tree digest includes empty directories", %{root: root} do
    assert {:ok, before} = AppEngineManifest.build(root, opts())

    File.mkdir_p!(Path.join(root, "data/empty"))

    assert {:ok, after_change} = AppEngineManifest.build(root, opts())
    refute after_change["tree_sha256"] == before["tree_sha256"]
  end

  test "inventories extensionless non-executable Mach-O content", %{root: root} do
    native_path = Path.join(root, "lib/runtime_native")
    File.write!(native_path, "fake-mach-o")
    File.chmod!(native_path, 0o644)

    classifier = fn path ->
      case Path.basename(path) do
        name when name in ["fermix_nif.so", "runtime_native"] ->
          {:ok, %{kind: "mach_o", architectures: ["arm64"]}}

        _script ->
          {:ok, %{kind: "script", interpreter: "/bin/sh"}}
      end
    end

    assert {:ok, manifest} =
             AppEngineManifest.build(root, Keyword.put(opts(), :classifier, classifier))

    assert Enum.find(manifest["inventory"]["entries"], &(&1["path"] == "lib/runtime_native"))[
             "kind"
           ] == "mach_o"
  end

  test "writing the in-tree manifest does not make its digest self-referential", %{root: root} do
    assert {:ok, first} = AppEngineManifest.write(root, opts())
    assert {:ok, second} = AppEngineManifest.write(root, opts())

    assert first == second

    decoded = root |> Path.join("engine-manifest.json") |> File.read!() |> Jason.decode!()
    assert decoded == first
  end

  test "rejects native files built for the wrong architecture", %{root: root} do
    classifier = fn path ->
      case Path.basename(path) do
        "fermix_nif.so" -> {:ok, %{kind: "mach_o", architectures: ["x86_64"]}}
        _script -> {:ok, %{kind: "script", interpreter: "/bin/sh"}}
      end
    end

    assert {:error, {:unexpected_architectures, "lib/fermix_nif.so", ["x86_64"], "arm64"}} =
             AppEngineManifest.build(root, Keyword.put(opts(), :classifier, classifier))
  end

  test "rejects unclassified executable content", %{root: root} do
    classifier = fn path ->
      if Path.basename(path) == "fermix_nif.so" do
        {:ok, %{kind: "mach_o", architectures: ["arm64"]}}
      else
        {:error, :unclassified_executable}
      end
    end

    assert {:error, {:unclassified_executable, "bin/fermix_app_engine"}} =
             AppEngineManifest.build(root, Keyword.put(opts(), :classifier, classifier))
  end

  test "rejects symlinks that escape the release tree", %{root: root} do
    File.ln_s!("../../outside", Path.join(root, "bin/escape"))

    assert {:error, {:symlink_escapes_root, "bin/escape"}} =
             AppEngineManifest.build(root, opts())
  end

  test "rejects symlinks whose nested target escapes the release tree", %{root: root} do
    outside = Path.join(Path.dirname(root), "outside")
    File.write!(outside, "outside")
    File.ln_s!("../../outside", Path.join(root, "bin/nested-target"))
    File.ln_s!("nested-target", Path.join(root, "bin/nested-link"))

    assert {:error, {:symlink_escapes_root, "bin/nested-link"}} =
             AppEngineManifest.build(root, opts())
  end

  test "rejects dangling symlinks inside the release tree", %{root: root} do
    File.ln_s!("missing", Path.join(root, "bin/dangling"))

    assert {:error, {:symlink_target_missing, "bin/dangling"}} =
             AppEngineManifest.build(root, opts())
  end

  test "rejects absolute symlink targets even when they currently resolve inside the tree", %{
    root: root
  } do
    target = Path.join(root, "bin/fermix_app_engine")
    File.ln_s!(target, Path.join(root, "bin/absolute"))

    assert {:error, {:symlink_absolute_target, "bin/absolute"}} =
             AppEngineManifest.build(root, opts())
  end

  test "classifies an empty regular file without crashing", %{root: root} do
    path = Path.join(root, "data/empty.dat")
    File.write!(path, "")

    assert {:error, :unclassified_executable} = ExecutableInventory.classify(path)
  end

  test "removes a partial temporary manifest after the initial write fails", %{root: root} do
    writer = fn temporary, contents, _modes ->
      File.write!(temporary, binary_part(contents, 0, 16))
      {:error, :enospc}
    end

    assert {:error, {:manifest_write_failed, :enospc}} =
             AppEngineManifest.write(root, Keyword.put(opts(), :write_file, writer))

    pattern = Path.join(Path.dirname(root), ".#{Path.basename(root)}-manifest-*.tmp")
    assert Path.wildcard(pattern) == []
  end

  defp opts do
    [
      identity: identity(),
      protocols: protocols(),
      classifier: &classifier/1
    ]
  end

  defp identity do
    %{
      engine_id: "fermix-core",
      product_version: "1.2.3",
      build_id: "release-123-attempt-1",
      source_commit: String.duplicate("a", 40),
      distribution_identity: "macos_app",
      artifact_target: "macos_aarch64",
      architecture: "arm64"
    }
  end

  defp public_identity do
    Map.new(identity(), fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp protocols do
    %{
      management: %{current_version: 1, minimum_version: 1, maximum_version: 1},
      realtime: %{current_version: 1, minimum_version: 1, maximum_version: 1}
    }
  end

  defp public_protocols do
    Map.new(protocols(), fn {name, range} ->
      {Atom.to_string(name), Map.new(range, fn {key, value} -> {Atom.to_string(key), value} end)}
    end)
  end

  defp classifier(path) do
    case Path.basename(path) do
      "fermix_nif.so" -> {:ok, %{kind: "mach_o", architectures: ["arm64"]}}
      _script -> {:ok, %{kind: "script", interpreter: "/bin/sh"}}
    end
  end
end
