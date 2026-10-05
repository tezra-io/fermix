defmodule FermixCore.IMessage.HelperInstallerTest do
  use ExUnit.Case, async: false

  alias FermixCore.IMessage.HelperInstaller
  alias FermixTestSupport.SafeRm

  @archive "fermix-messages-zip-bytes\n"
  @archive_sha256 :sha256 |> :crypto.hash(@archive) |> Base.encode16(case: :lower)
  @signed_by_fermix "Executable=/x\nIdentifier=io.tezra.fermix.messages\nTeamIdentifier=54A57TH9BJ\n"

  setup do
    previous_home = System.get_env("FERMIX_HOME")
    previous_plugins = Application.get_env(:fermix_core, :plugins)
    home = SafeRm.make_tmp_dir!("imessage-helper-installer")
    System.put_env("FERMIX_HOME", home)
    Application.delete_env(:fermix_core, :plugins)

    on_exit(fn ->
      restore_env(previous_home)
      restore_plugins(previous_plugins)
      SafeRm.rm_rf(home)
    end)

    %{home: home}
  end

  def archive_plug(%Plug.Conn{} = conn), do: Plug.Conn.send_resp(conn, 200, @archive)

  test "the stable identifiers the setup surfaces key off" do
    assert HelperInstaller.plugin_name() == "imessage_helper"
    assert HelperInstaller.pinned_version() == "0.1.2"
  end

  describe "install/1" do
    test "the shipped pin names the first release by its sha256" do
      assert %{"0.1.2" => %{"macos-universal" => %{url: url, sha256: sha}}} =
               HelperInstaller.releases()

      assert url =~ "/releases/download/v0.1.2/fermix-messages-0.1.2-macos-universal.zip"
      assert String.match?(sha, ~r/^[0-9a-f]{64}$/)
    end

    test "a pin that is not set refuses rather than downloading" do
      releases = %{
        "0.1.2" => %{"macos-universal" => %{url: "https://example.invalid/x.zip", sha256: "TBD"}}
      }

      assert HelperInstaller.install(
               install_opts(runner: fn _cmd, _args -> flunk("ran") end)
               |> Keyword.put(:releases, releases)
             ) == {:error, :pin_not_set}
    end

    test "refuses off a Mac before anything is fetched" do
      assert HelperInstaller.install(
               install_opts(runner: fn _cmd, _args -> flunk("ran") end)
               |> Keyword.put(:macos?, false)
             ) ==
               {:error, {:unsupported_platform, :imessage}}
    end

    test "downloads, verifies, extracts, checks the signature and places the bundle",
         %{home: home} do
      {runner, calls} = recording_runner()

      assert {:ok, binary} = HelperInstaller.install(install_opts(runner: runner))

      app =
        Path.join([home, "plugins", "imessage_helper", "0.1.2", "macos-universal", app_name()])

      assert binary == Path.join([app, "Contents", "MacOS", "fermix-messages"])
      assert File.regular?(binary)

      assert [
               {"/usr/bin/ditto", ["-x", "-k", _zip, _staging]},
               {"/usr/bin/codesign", ["--verify", "--deep", "--strict", staged]},
               {"/usr/bin/codesign", ["-dv", staged]},
               {lsregister, ["-f", ^app]}
             ] = calls.()

      assert String.ends_with?(staged, app_name())
      assert String.ends_with?(lsregister, "/lsregister")
      assert leftovers(home) == []
    end

    test "a checksum mismatch places nothing and leaves no partial file", %{home: home} do
      wrong = String.duplicate("0", 64)

      assert {:error, {:checksum_mismatch, ^wrong, @archive_sha256}} =
               HelperInstaller.install(install_opts(sha256: wrong))

      refute HelperInstaller.installed?()
      assert leftovers(home) == []
    end

    test "a bundle that fails codesign verification is never placed", %{home: home} do
      runner =
        fake_runner(verify: {"invalid signature (code or signature have been modified)", 1})

      assert {:error, {:helper_unverified, output}} =
               HelperInstaller.install(install_opts(runner: runner))

      assert output =~ "invalid signature"
      refute HelperInstaller.installed?()
      assert leftovers(home) == []
    end

    test "a bundle signed by another team is never placed", %{home: home} do
      runner =
        fake_runner(
          describe: {"Identifier=io.tezra.fermix.messages\nTeamIdentifier=ZZZZZZZZZZ\n", 0}
        )

      assert {:error, {:helper_unverified, :team_id_mismatch}} =
               HelperInstaller.install(install_opts(runner: runner))

      refute HelperInstaller.installed?()
      assert leftovers(home) == []
    end

    test "an archive that holds no Fermix Messages bundle is refused", %{home: home} do
      runner = fake_runner(extract: :nothing)

      assert {:error, {:helper_unverified, :bundle_missing}} =
               HelperInstaller.install(install_opts(runner: runner))

      assert leftovers(home) == []
    end

    test "a second install of a verified bundle downloads nothing" do
      counter = :counters.new(1, [:atomics])
      opts = install_opts(req_options: [plug: counting_plug(counter)])

      assert {:ok, binary} = HelperInstaller.install(opts)
      assert HelperInstaller.install(opts) == {:ok, binary}
      assert :counters.get(counter, 1) == 1, "the second install downloaded the archive again"
    end

    test "a registration failure is the install's failure" do
      runner = fake_runner(lsregister: {"lsregister: failed", 3})

      assert {:error, {:lsregister_failed, 3, "lsregister: failed"}} =
               HelperInstaller.install(install_opts(runner: runner))
    end
  end

  describe "resolution without downloading" do
    test "nothing installed resolves nothing" do
      refute HelperInstaller.installed?()
      assert HelperInstaller.binary_path() == {:error, :not_installed}
    end

    test "a dev_local bundle wins and satisfies installed?", %{home: home} do
      root = Path.join(home, "dev-plugins")
      Application.put_env(:fermix_core, :plugins, dev_local: root)

      binary =
        Path.join([
          root,
          "imessage_helper",
          "bin",
          "macos-universal",
          app_name(),
          "Contents",
          "MacOS",
          "fermix-messages"
        ])

      write_executable!(binary)

      assert HelperInstaller.binary_path() == {:ok, binary}
      assert HelperInstaller.installed?()
    end

    test "the cached install for the pinned version resolves", %{home: home} do
      binary =
        Path.join([
          home,
          "plugins",
          "imessage_helper",
          "0.1.2",
          "macos-universal",
          app_name(),
          "Contents",
          "MacOS",
          "fermix-messages"
        ])

      write_executable!(binary)

      assert HelperInstaller.binary_path() == {:ok, binary}

      assert HelperInstaller.bundle_path() ==
               {:ok, Path.dirname(Path.dirname(Path.dirname(binary)))}

      assert HelperInstaller.installed?()
    end

    test "a binary without the exec bit is not installed", %{home: home} do
      binary =
        Path.join([
          home,
          "plugins",
          "imessage_helper",
          "0.1.2",
          "macos-universal",
          app_name(),
          "Contents",
          "MacOS",
          "fermix-messages"
        ])

      write_executable!(binary)
      File.chmod!(binary, 0o644)

      refute HelperInstaller.installed?()
    end
  end

  describe "verify_bundle/2" do
    test "a strict-valid bundle signed by the Fermix team passes" do
      assert HelperInstaller.verify_bundle("/x/#{app_name()}", runner: fake_runner([])) == :ok
    end

    test "names the codesign output of a bundle that does not verify" do
      runner = fake_runner(verify: {"code object is not signed at all", 1})

      assert HelperInstaller.verify_bundle("/x/#{app_name()}", runner: runner) ==
               {:error, {:helper_unverified, "code object is not signed at all"}}
    end
  end

  defp install_opts(overrides) do
    sha256 = Keyword.get(overrides, :sha256, @archive_sha256)

    Keyword.merge(
      [
        macos?: true,
        releases: %{
          "0.1.2" => %{
            "macos-universal" => %{url: "https://example.invalid/helper.zip", sha256: sha256}
          }
        },
        req_options: [plug: &__MODULE__.archive_plug/1],
        runner: fake_runner([])
      ],
      Keyword.delete(overrides, :sha256)
    )
  end

  # Stands in for ditto, codesign and lsregister: `ditto` lays a bundle into the
  # staging directory it is handed, exactly where the real extraction would.
  defp fake_runner(overrides) do
    fn
      "/usr/bin/ditto", ["-x", "-k", _zip, staging] ->
        extract(staging, Keyword.get(overrides, :extract, :bundle))

      "/usr/bin/codesign", ["--verify" | _rest] ->
        Keyword.get(overrides, :verify, {"", 0})

      "/usr/bin/codesign", ["-dv", _app] ->
        Keyword.get(overrides, :describe, {@signed_by_fermix, 0})

      _lsregister, ["-f", _app] ->
        Keyword.get(overrides, :lsregister, {"", 0})
    end
  end

  defp recording_runner do
    agent = start_supervised!({Agent, fn -> [] end})
    runner = fake_runner([])

    recording = fn cmd, args ->
      Agent.update(agent, &(&1 ++ [{cmd, args}]))
      runner.(cmd, args)
    end

    {recording, fn -> Agent.get(agent, & &1) end}
  end

  defp extract(_staging, :nothing), do: {"", 0}

  defp extract(staging, :bundle) do
    write_executable!(Path.join([staging, app_name(), "Contents", "MacOS", "fermix-messages"]))
    {"", 0}
  end

  defp counting_plug(counter) do
    fn %Plug.Conn{} = conn ->
      :counters.add(counter, 1, 1)
      Plug.Conn.send_resp(conn, 200, @archive)
    end
  end

  # Anything but the placed bundle left under the helper's plugin root: a partial
  # download or a staging directory is a leak.
  defp leftovers(home) do
    root = Path.join([home, "plugins", "imessage_helper"])

    case File.ls(root) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry -> version_leftovers(Path.join(root, entry)) end)

      {:error, :enoent} ->
        []
    end
  end

  defp version_leftovers(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.reject(entries, &(&1 == "macos-universal"))
      {:error, _reason} -> [Path.basename(dir)]
    end
  end

  defp write_executable!(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\n")
    File.chmod!(path, 0o755)
  end

  defp app_name, do: "Fermix Messages.app"

  defp restore_env(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_env(value), do: System.put_env("FERMIX_HOME", value)

  defp restore_plugins(nil), do: Application.delete_env(:fermix_core, :plugins)
  defp restore_plugins(value), do: Application.put_env(:fermix_core, :plugins, value)
end
