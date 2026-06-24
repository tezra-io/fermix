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

  describe "parse_ps_pid/2 (existing-Chrome reuse detection)" do
    test "finds the os pid for an exact user-data-dir match" do
      output = Enum.join([ps_line(78_009, @dir, 0), "999 /usr/bin/something else"], "\n")
      assert {:ok, 78_009} = ChromeLauncher.parse_ps_pid(output, @dir)
    end

    test "does not match a different profile that shares a path prefix" do
      # ".../fermix" must not match a process for ".../fermix_visible".
      output = ps_line(81_806, @dir <> "_visible", 0)
      assert :none = ChromeLauncher.parse_ps_pid(output, @dir)
    end

    test "returns :none when no process owns the dir" do
      output = "111 /usr/bin/Xorg\n222 /Applications/Safari.app/Contents/MacOS/Safari"
      assert :none = ChromeLauncher.parse_ps_pid(output, @dir)
    end
  end

  describe "read_devtools_port/1" do
    test "reads the port from the first line of DevToolsActivePort", %{home: home} do
      dir = Path.join(home, "profile")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "DevToolsActivePort"), "51234\n/devtools/browser/abc")

      assert {:ok, 51_234} = ChromeLauncher.read_devtools_port(dir)
    end

    test "errors when the file is missing", %{home: home} do
      assert {:error, :no_devtools_port} =
               ChromeLauncher.read_devtools_port(Path.join(home, "nope"))
    end

    test "errors when the first line is not a port", %{home: home} do
      dir = Path.join(home, "garbage")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "DevToolsActivePort"), "not-a-port\n")

      assert {:error, :no_devtools_port} = ChromeLauncher.read_devtools_port(dir)
    end
  end

  describe "attach/4" do
    test "returns :none for non-managed profiles" do
      {:ok, config} = Config.current()
      assert :none = ChromeLauncher.attach(config, %{mode: :existing_session}, "owner", "user")
    end
  end

  describe "start/4" do
    test "asks Chrome to self-assign the port, resolves it from DevToolsActivePort, then reaps on failure",
         %{home: home} do
      {executable, requested_marker, bound_marker} = fake_cdp_listener!(home)

      {:ok, config} =
        Config.current(
          launch_timeout_ms: 3_000,
          cdp_ready_poll_interval_ms: 20,
          cdp_version_probe_timeout_ms: 20,
          stop_grace_ms: 50,
          kill_grace_ms: 50
        )

      profile = %{mode: :managed, headless: true, cdp_port: :auto, executable_path: executable}

      assert {:error, error} = ChromeLauncher.start(config, profile, "owner", "smoke")
      assert error.code == "cdp_not_ready"

      # No Fermix-side range scan: we asked Chrome to self-assign (port 0), which
      # removes the check-then-bind race two concurrent launches had.
      assert eventually_file(requested_marker) == "0"

      # The launcher learned the real OS-assigned port from DevToolsActivePort and
      # reaped the unready Chrome (its bound port is freed).
      bound = eventually_file(bound_marker) |> String.to_integer()
      assert eventually_port_free?(bound)
    end
  end

  # Fake Chrome: binds an OS-assigned port (like `--remote-debugging-port=0`),
  # publishes it in the profile's DevToolsActivePort, records the requested and
  # bound ports, and never serves `/json/version` — so readiness fails and the
  # launcher must reap it.
  defp fake_cdp_listener!(home) do
    path = Path.join(home, "fake-chrome")
    requested_marker = Path.join(home, "fake-chrome-requested")
    bound_marker = Path.join(home, "fake-chrome-bound")

    File.write!(path, """
    #!/usr/bin/env elixir
    args = System.argv()

    requested =
      Enum.find_value(args, fn
        "--remote-debugging-port=" <> value -> value
        _other -> nil
      end)

    dir =
      Enum.find_value(args, fn
        "--user-data-dir=" <> value -> value
        _other -> nil
      end)

    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, bound} = :inet.port(socket)
    File.write!(Path.join(dir, "DevToolsActivePort"), Integer.to_string(bound) <> "\\n/devtools/browser/fake")
    File.write!(#{inspect(requested_marker)}, requested)
    File.write!(#{inspect(bound_marker)}, Integer.to_string(bound))
    Process.sleep(:infinity)
    """)

    File.chmod!(path, 0o700)
    {path, requested_marker, bound_marker}
  end

  defp eventually_file(path), do: eventually_file(path, 100)
  defp eventually_file(_path, 0), do: flunk("marker file never appeared")

  defp eventually_file(path, attempts) do
    case File.read(path) do
      {:ok, contents} when contents != "" ->
        contents

      _other ->
        Process.sleep(20)
        eventually_file(path, attempts - 1)
    end
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
