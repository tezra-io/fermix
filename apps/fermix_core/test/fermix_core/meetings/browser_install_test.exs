defmodule FermixCore.Meetings.BrowserInstallTest do
  use ExUnit.Case, async: false

  alias FermixCore.Meetings.BrowserInstall

  @fake Path.expand("fake_install_browser.pl", __DIR__)

  setup do
    prev_home = System.get_env("FERMIX_HOME")
    prev_plugins = Application.get_env(:fermix_core, :plugins)

    home =
      Path.join([
        System.tmp_dir!(),
        "fermix-browser-install",
        "home-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(home)
    System.put_env("FERMIX_HOME", home)
    # No dev_local build → SidecarInstaller.binary_path/0 reports not-installed.
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

    %{home: home}
  end

  # Drives the real spawn path (an ordinary Port — no disclaim shim, no GUI)
  # against the fake, which speaks the sidecar's NDJSON and exits with the code.
  defp run(mode, opts \\ []) do
    BrowserInstall.run([binary_path: @fake, args: [mode]] ++ opts)
  end

  defp marker_path(home), do: Path.join([home, "plugins", "meetbot", "browser_installed"])

  describe "run/1 verdicts" do
    test "a fresh download reports :installed and records the marker", %{home: home} do
      assert run("ok") == {:ok, :installed}
      assert File.regular?(marker_path(home))
    end

    test "an already-present browser reports :already and still marks it", %{home: home} do
      assert run("already") == {:ok, :already}
      assert File.regular?(marker_path(home))
    end

    test "a nonzero exit is a browser-install failure carrying the code", %{home: home} do
      assert run("error") == {:error, {:browser_install_failed, 1}}
      refute File.exists?(marker_path(home))
    end
  end

  describe "run/1 progress" do
    test "each status line reaches the progress callback in order" do
      me = self()

      assert run("ok", progress: fn event -> send(me, {:browser_event, event}) end) ==
               {:ok, :installed}

      assert_received {:browser_event, {:state, :checking}}
      assert_received {:browser_event, {:state, :downloading}}
      assert_received {:browser_event, {:state, :installed}}
      assert_received {:browser_event, {:result, :ok}}
    end
  end

  # The Chromium `install-browser` leaves behind is the task browser's last
  # candidate, so where it landed is answered from Playwright's own layout. The
  # cache is a tmp tree each case builds, never the host's.
  describe "chromium_path/1" do
    @mac_layout [
      "chrome-mac-arm64",
      "Google Chrome for Testing.app",
      "Contents",
      "MacOS",
      "Google Chrome for Testing"
    ]

    setup %{home: home} do
      %{root: Path.join(home, "ms-playwright")}
    end

    test "answers the newest complete revision, by number rather than spelling", %{root: root} do
      old = install_chromium(root, "chromium-999", @mac_layout)
      newest = install_chromium(root, "chromium-1234", @mac_layout)

      assert BrowserInstall.chromium_path(root: root, target: "macos-aarch64") == {:ok, newest}
      refute old == newest
    end

    test "skips a revision whose download never finished", %{root: root} do
      finished = install_chromium(root, "chromium-1200", @mac_layout)
      install_chromium(root, "chromium-1300", @mac_layout, complete: false)

      assert BrowserInstall.chromium_path(root: root, target: "macos-aarch64") == {:ok, finished}
    end

    test "ignores the headless shell and the tip-of-tree builds beside it", %{root: root} do
      install_chromium(root, "chromium_headless_shell-2000", @mac_layout)
      install_chromium(root, "chromium-tip-of-tree-2001", @mac_layout)

      assert BrowserInstall.chromium_path(root: root, target: "macos-aarch64") ==
               {:error, :not_installed}
    end

    test "reads each target's own layout", %{root: root} do
      linux = install_chromium(root, "chromium-1234", ["chrome-linux64", "chrome"])

      assert BrowserInstall.chromium_path(root: root, target: "linux-x86_64") == {:ok, linux}

      assert BrowserInstall.chromium_path(root: root, target: "macos-aarch64") ==
               {:error, :not_installed}
    end

    test "a missing cache and a machine with no layout are both not installed", %{root: root} do
      assert BrowserInstall.chromium_path(root: root, target: "macos-aarch64") ==
               {:error, :not_installed}

      install_chromium(root, "chromium-1234", @mac_layout)

      assert BrowserInstall.chromium_path(root: root, target: "plan9-mips") ==
               {:error, :not_installed}
    end

    test "follows PLAYWRIGHT_BROWSERS_PATH, as the sidecar that inherits it does", %{root: root} do
      previous = System.get_env("PLAYWRIGHT_BROWSERS_PATH")
      on_exit(fn -> restore_env("PLAYWRIGHT_BROWSERS_PATH", previous) end)
      path = install_chromium(root, "chromium-1234", @mac_layout)

      System.put_env("PLAYWRIGHT_BROWSERS_PATH", root)

      assert BrowserInstall.chromium_path(target: "macos-aarch64") == {:ok, path}
    end
  end

  describe "run/1 refusals" do
    test "refuses loud when the sidecar binary is not installed" do
      # No binary_path seam and nothing installed → the binary must come first.
      assert BrowserInstall.run() == {:error, :not_installed}
    end
  end

  defp install_chromium(root, revision, layout, opts \\ []) do
    dir = Path.join(root, revision)
    executable = Path.join([dir | layout])
    File.mkdir_p!(Path.dirname(executable))
    File.write!(executable, "#!/bin/sh\n")

    if Keyword.get(opts, :complete, true),
      do: File.write!(Path.join(dir, "INSTALLATION_COMPLETE"), "")

    executable
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
