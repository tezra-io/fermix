defmodule Fermix.CLI.Setup.WebLauncherTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.Setup.WebLauncher

  setup do
    previous_home = System.get_env("FERMIX_HOME")
    previous_port = System.get_env("PORT")
    home = FermixTestSupport.SafeRm.make_tmp_dir!("setup-web-launcher")
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      case previous_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      case previous_port do
        nil -> System.delete_env("PORT")
        value -> System.put_env("PORT", value)
      end

      FermixTestSupport.SafeRm.rm_rf!(home)
    end)

    %{home: home}
  end

  test "wait_for_live returns once the probe succeeds and sleeps between bounded attempts" do
    parent = self()

    probe = fn ->
      send(parent, :probe)

      case Process.get(:probe_count, 0) do
        0 ->
          Process.put(:probe_count, 1)
          {:error, :not_ready}

        _count ->
          :ok
      end
    end

    assert :ok = WebLauncher.wait_for_live(live_probe: probe, sleep: sleep(parent))
    assert_received :probe
    assert_received {:sleep, 500}
  end

  test "wait_for_live times out without unbounded polling" do
    parent = self()

    assert {:error, :timeout} =
             WebLauncher.wait_for_live(
               live_probe: fn ->
                 send(parent, :probe)
                 {:error, :not_ready}
               end,
               sleep: sleep(parent),
               max_attempts: 2,
               interval_ms: 7
             )

    assert_received :probe
    assert_received :probe
    assert_received {:sleep, 7}
    assert_received {:sleep, 7}
    refute_received :probe
  end

  test "run leaves the service up and prints guidance when live wait times out" do
    output =
      capture_io(fn ->
        assert :ok =
                 WebLauncher.run(
                   scope: :user,
                   no_browser: true,
                   service: fake_service(installed?: false),
                   standalone?: fn -> true end,
                   live_probe: fn -> {:error, :not_ready} end,
                   sleep: fn _ms -> :ok end,
                   max_attempts: 1
                 )
      end)

    assert output =~ "readiness did not answer before the timeout"
    assert output =~ "http://127.0.0.1:4030/setup?t="
    assert output =~ "fermix status"
  end

  test "run uses PORT when no explicit setup port is passed" do
    System.put_env("PORT", "4545")

    output =
      capture_io(fn ->
        assert :ok =
                 WebLauncher.run(
                   scope: :user,
                   no_browser: true,
                   service: fake_service(installed?: false),
                   standalone?: fn -> true end,
                   live_probe: fn -> :ok end
                 )
      end)

    assert output =~ "http://127.0.0.1:4545/setup?t="
  end

  test "browser open failures print manual guidance and still exit cleanly" do
    output =
      capture_io(fn ->
        assert :ok =
                 WebLauncher.run(
                   scope: :user,
                   service: fake_service(installed?: true),
                   standalone?: fn -> true end,
                   live_probe: fn -> :ok end,
                   opener: fn _url -> {:error, :no_opener} end
                 )
      end)

    assert output =~ "Could not open a browser automatically"
    assert output =~ "Finish setup in your browser"
  end

  test "prints an SSH tunnel hint for forced web setup on a headless host" do
    output =
      capture_io(fn ->
        assert :ok =
                 WebLauncher.run(
                   scope: :user,
                   port: 4041,
                   ssh_hint: true,
                   no_browser: true,
                   service: fake_service(installed?: true),
                   standalone?: fn -> true end,
                   live_probe: fn -> :ok end
                 )
      end)

    assert output =~ "ssh -L 4041:127.0.0.1:4041 user@host"
  end

  test "returns a clear error when activation is skipped", %{home: home} do
    assert {:error, message} =
             WebLauncher.run(
               scope: :user,
               no_browser: true,
               service: fake_service(installed?: false),
               standalone?: fn -> false end
             )

    assert message =~ "standalone binary"
    refute File.exists?(Path.join(home, "setup-launch-token.json"))
  end

  defp sleep(parent) do
    fn ms -> send(parent, {:sleep, ms}) end
  end

  defp fake_service(opts) do
    installed? = Keyword.fetch!(opts, :installed?)

    %{
      installed?: fn _scope, _opts -> installed? end,
      install: fn _scope, _opts -> :ok end,
      start: fn _scope, _opts -> :ok end,
      restart: fn _scope, _opts -> :ok end
    }
  end
end
