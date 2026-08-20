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

  describe "run/1 refusals" do
    test "refuses loud when the sidecar binary is not installed" do
      # No binary_path seam and nothing installed → the binary must come first.
      assert BrowserInstall.run() == {:error, :not_installed}
    end
  end
end
