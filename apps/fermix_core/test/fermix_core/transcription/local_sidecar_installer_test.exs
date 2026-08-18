defmodule FermixCore.Transcription.Local.SidecarInstallerTest do
  # async: false — every test repoints FERMIX_HOME and the plugins app env.
  use ExUnit.Case, async: false

  alias FermixCore.Transcription.Local.SidecarInstaller

  @artifact "fermix-stt-fake-binary\n"
  @artifact_sha256 :sha256 |> :crypto.hash(@artifact) |> Base.encode16(case: :lower)

  setup do
    prev_home = System.get_env("FERMIX_HOME")
    prev_plugins = Application.get_env(:fermix_core, :plugins)

    home = FermixTestSupport.SafeRm.make_tmp_dir!("fermix-stt-installer")
    System.put_env("FERMIX_HOME", home)
    Application.delete_env(:fermix_core, :plugins)

    on_exit(fn ->
      case prev_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      case prev_plugins do
        nil -> Application.delete_env(:fermix_core, :plugins)
        value -> Application.put_env(:fermix_core, :plugins, value)
      end

      FermixTestSupport.SafeRm.rm_rf(home)
    end)

    {:ok, target} = SidecarInstaller.target()
    %{home: home, target: target}
  end

  def artifact_plug(%Plug.Conn{} = conn), do: Plug.Conn.send_resp(conn, 200, @artifact)

  test "plugin_name is the stable card identifier" do
    assert SidecarInstaller.plugin_name() == "stt_sidecar"
  end

  test "target resolves to a supported artifact string on this host", %{target: target} do
    assert target in ~w(macos-aarch64 macos-x86_64 linux-x86_64 linux-aarch64)
  end

  describe "install/1 with no pinned release" do
    test "refuses rather than downloading something unpinned" do
      assert SidecarInstaller.install() == {:error, :no_release_pinned}
    end

    test "a releases table without an entry for this host refuses the same way" do
      assert SidecarInstaller.install(
               releases: %{"solaris-sparc" => %{url: "http://x/y", sha256: @artifact_sha256}}
             ) == {:error, :no_release_pinned}
    end

    test "carries the operator copy doctor and setup render verbatim" do
      assert SidecarInstaller.error_message(:no_release_pinned) ==
               "fermix-stt has no pinned release yet. Build it locally and point " <>
                 "[fermix_core.plugins] dev_local at a checkout containing " <>
                 "stt_sidecar/bin/<target>/fermix-stt."
    end
  end

  describe "install/1 with a pinned release" do
    test "downloads, verifies, and installs executable", %{home: home, target: target} do
      assert {:ok, path} =
               SidecarInstaller.install(
                 releases: releases(target, @artifact_sha256),
                 req_options: [plug: &__MODULE__.artifact_plug/1]
               )

      assert path == Path.join([home, "plugins", "stt", "bin", target, "fermix-stt"])
      assert File.read!(path) == @artifact
      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o111) != 0
      assert SidecarInstaller.installed?()
      assert SidecarInstaller.binary_path() == {:ok, path}
    end

    test "a checksum mismatch installs nothing and leaves no partial file", %{
      home: home,
      target: target
    } do
      wrong = String.duplicate("0", 64)

      assert {:error, {:checksum_mismatch, ^wrong, actual}} =
               SidecarInstaller.install(
                 releases: releases(target, wrong),
                 req_options: [plug: &__MODULE__.artifact_plug/1]
               )

      assert actual == @artifact_sha256
      assert File.ls!(Path.join([home, "plugins", "stt", "bin", target])) == []
      refute SidecarInstaller.installed?()
    end
  end

  describe "resolution without downloading" do
    test "not installed with neither a dev_local build nor a downloaded binary" do
      refute SidecarInstaller.installed?()
      assert SidecarInstaller.binary_path() == {:error, :not_installed}
    end

    test "a dev_local build wins and satisfies installed?", %{home: home, target: target} do
      binary = dev_local_binary(home, target, 0o755)

      assert SidecarInstaller.binary_path() == {:ok, binary}
      assert SidecarInstaller.installed?()
    end

    test "a dev_local build without the exec bit is not installed", %{
      home: home,
      target: target
    } do
      dev_local_binary(home, target, 0o644)

      refute SidecarInstaller.installed?()
    end

    test "a dev_local root with no built binary resolves nothing", %{home: home} do
      Application.put_env(:fermix_core, :plugins, dev_local: Path.join(home, "dev-plugins"))

      assert SidecarInstaller.binary_path() == {:error, :not_installed}
    end
  end

  defp releases(target, sha256),
    do: %{target => %{url: "http://stt.test/fermix-stt", sha256: sha256}}

  defp dev_local_binary(home, target, mode) do
    path = Path.join([home, "dev-plugins", "stt_sidecar", "bin", target, "fermix-stt"])

    Application.put_env(:fermix_core, :plugins, dev_local: Path.join(home, "dev-plugins"))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\n")
    File.chmod!(path, mode)
    path
  end
end
