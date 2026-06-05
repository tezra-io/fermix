defmodule FermixCore.Browser.ChromeLauncherTest do
  use ExUnit.Case, async: false

  alias FermixCore.Browser.ChromeLauncher
  alias FermixCore.Browser.Config

  @dir "/home/u/.fermix/browser/profiles/abc/fermix"

  setup do
    previous_home = System.get_env("FERMIX_HOME")
    home = FermixTestSupport.SafeRm.make_tmp_dir!("browser-chrome-launcher")
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      restore_env("FERMIX_HOME", previous_home)
      FermixTestSupport.SafeRm.rm_rf!(home)
    end)

    %{home: home}
  end

  defp ps_line(pid, dir, port) do
    "#{pid} /Applications/Google Chrome.app/Contents/MacOS/Google Chrome " <>
      "--user-data-dir=#{dir} --remote-debugging-port=#{port} --headless=new about:blank"
  end

  describe "parse_ps_output/2 (existing-Chrome reuse detection)" do
    test "finds the pid and cdp port for an exact user-data-dir match" do
      output = Enum.join([ps_line(78_009, @dir, 18_805), "999 /usr/bin/something else"], "\n")
      assert {78_009, 18_805} = ChromeLauncher.parse_ps_output(output, @dir)
    end

    test "does not match a different profile that shares a path prefix" do
      # ".../fermix" must not match a process for ".../fermix_visible".
      output = ps_line(81_806, @dir <> "_visible", 18_806)
      assert :none = ChromeLauncher.parse_ps_output(output, @dir)
    end

    test "returns :none when no process owns the dir" do
      output = "111 /usr/bin/Xorg\n222 /Applications/Safari.app/Contents/MacOS/Safari"
      assert :none = ChromeLauncher.parse_ps_output(output, @dir)
    end

    test "ignores a matching dir with no debugging port" do
      output =
        "500 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=#{@dir}"

      assert :none = ChromeLauncher.parse_ps_output(output, @dir)
    end
  end

  describe "attach/4" do
    test "returns :none for non-managed profiles" do
      {:ok, config} = Config.current()
      assert :none = ChromeLauncher.attach(config, %{mode: :existing_session}, "owner", "user")
    end
  end

  describe "start/4" do
    test "auto launch uses smoke CDP range and frees the port after failed readiness", %{
      home: home
    } do
      {executable, marker} = fake_cdp_listener!(home)

      {:ok, config} =
        Config.current(
          cdp_port_range: 19_100..19_199,
          launch_timeout_ms: 1_000,
          cdp_ready_poll_interval_ms: 20,
          cdp_version_probe_timeout_ms: 20,
          stop_grace_ms: 50,
          kill_grace_ms: 50
        )

      profile = %{mode: :managed, headless: true, cdp_port: :auto, executable_path: executable}

      assert {:error, error} = ChromeLauncher.start(config, profile, "owner", "smoke")
      assert error.code == "cdp_not_ready"
      assert error.details["port"] in 19_100..19_199
      assert File.read!(marker) == Integer.to_string(error.details["port"])
      assert eventually_port_free?(error.details["port"])
    end
  end

  defp fake_cdp_listener!(home) do
    path = Path.join(home, "fake-chrome")
    marker = Path.join(home, "fake-chrome-bound")

    File.write!(path, """
    #!/usr/bin/env elixir
    port =
      System.argv()
      |> Enum.find_value(fn
        "--remote-debugging-port=" <> value -> String.to_integer(value)
        _other -> nil
      end)

    {:ok, _socket} = :gen_tcp.listen(port, [:binary, active: false, ip: {127, 0, 0, 1}])
    File.write!(#{inspect(marker)}, Integer.to_string(port))
    Process.sleep(:infinity)
    """)

    File.chmod!(path, 0o700)
    {path, marker}
  end

  defp eventually_port_free?(port), do: eventually_port_free?(port, 20)

  defp eventually_port_free?(port, attempts) when attempts > 0 do
    if port_free?(port) do
      true
    else
      Process.sleep(10)
      eventually_port_free?(port, attempts - 1)
    end
  end

  defp eventually_port_free?(_port, 0), do: false

  defp port_free?(port) do
    case :gen_tcp.listen(port, [:binary, active: false, ip: {127, 0, 0, 1}]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
