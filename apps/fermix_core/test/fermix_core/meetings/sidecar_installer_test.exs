defmodule FermixCore.Meetings.SidecarInstallerTest do
  use ExUnit.Case, async: false

  alias FermixCore.Meetings.SidecarInstaller

  @artifact "meetbot-fake-binary\n"
  @artifact_sha256 :sha256 |> :crypto.hash(@artifact) |> Base.encode16(case: :lower)

  setup do
    prev_home = System.get_env("FERMIX_HOME")
    prev_plugins = Application.get_env(:fermix_core, :plugins)

    home =
      Path.join([
        System.tmp_dir!(),
        "fermix-meetbot-installer",
        "home-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(home)
    System.put_env("FERMIX_HOME", home)

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
    assert SidecarInstaller.plugin_name() == "meetbot_sidecar"
  end

  test "target resolves to a supported artifact string on this host", %{target: target} do
    assert target in ~w(macos-aarch64 macos-x86_64 linux-x86_64 linux-aarch64)
  end

  test "the profile lives inside the fermix home, never in the OS browser profile", %{home: home} do
    assert SidecarInstaller.profile_dir() == Path.join([home, "plugins", "meetbot", "profile"])
  end

  describe "install/1 with no pinned release" do
    test "refuses rather than downloading something unpinned" do
      assert SidecarInstaller.pinned_tag() == nil
      assert SidecarInstaller.install() == {:error, :no_pinned_release}
    end

    test "carries the operator copy the setup card renders verbatim" do
      assert SidecarInstaller.error_message(:no_pinned_release) ==
               "No meetbot sidecar release is pinned in this fermix build yet. " <>
                 "For development, set [fermix_core.plugins] dev_local to a fermix-meetbot " <>
                 "checkout with a built binary at meetbot_sidecar/bin/<target>/fermix-meetbot."
    end
  end

  describe "install/1 with a pinned release" do
    test "downloads, verifies, and installs executable", %{home: home, target: target} do
      assert {:ok, path} =
               SidecarInstaller.install(
                 pinned_tag: "v0.1.0",
                 releases: %{"v0.1.0" => %{target => @artifact_sha256}},
                 req_options: [plug: &__MODULE__.artifact_plug/1]
               )

      assert path == Path.join([home, "plugins", "meetbot", "bin", "v0.1.0", "fermix-meetbot"])
      assert File.read!(path) == @artifact
      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o111) != 0
    end

    test "a checksum mismatch installs nothing and leaves no partial file", %{
      home: home,
      target: target
    } do
      wrong = String.duplicate("0", 64)

      assert {:error, {:checksum_mismatch, ^wrong, actual}} =
               SidecarInstaller.install(
                 pinned_tag: "v0.1.0",
                 releases: %{"v0.1.0" => %{target => wrong}},
                 req_options: [plug: &__MODULE__.artifact_plug/1]
               )

      assert actual == @artifact_sha256

      bin_dir = Path.join([home, "plugins", "meetbot", "bin", "v0.1.0"])
      assert File.ls!(bin_dir) == []
    end

    test "a tag with no artifact for this host refuses loud", %{target: target} do
      assert SidecarInstaller.install(
               pinned_tag: "v0.1.0",
               releases: %{"v0.1.0" => %{"solaris-sparc" => @artifact_sha256}}
             ) == {:error, {:no_pinned_artifact, "v0.1.0", target}}
    end
  end

  describe "resolution without downloading" do
    test "installed? is false with neither a dev_local build nor a cached binary" do
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

  defp dev_local_binary(home, target, mode) do
    path =
      Path.join([home, "dev-plugins", "meetbot_sidecar", "bin", target, "fermix-meetbot"])

    Application.put_env(:fermix_core, :plugins, dev_local: Path.join(home, "dev-plugins"))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\n")
    File.chmod!(path, mode)
    path
  end
end
