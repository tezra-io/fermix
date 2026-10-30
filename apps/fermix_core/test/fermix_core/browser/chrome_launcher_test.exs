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

  # Which browser a task runs in. Every case injects the installed browsers and
  # the downloaded one's cache, so the host's own Chrome never decides a verdict.
  describe "resolve/3 and candidates/2" do
    setup %{home: home} do
      previous = System.get_env("CHROME_PATH")
      System.delete_env("CHROME_PATH")
      on_exit(fn -> restore_env("CHROME_PATH", previous) end)

      root = Path.join(home, "ms-playwright")
      downloaded = install_chromium(root, "chromium-1234")

      %{
        downloaded: downloaded,
        opts: [downloaded: [root: root, target: "linux-x86_64"]],
        installed: fake_browser(home, "installed-chromium")
      }
    end

    test "the configured path leads and the downloaded Chromium comes last", context do
      configured = fake_browser(context.home, "configured")
      System.put_env("CHROME_PATH", configured)
      opts = [installed: [{context.installed, "Chromium"}]] ++ context.opts

      assert ChromeLauncher.candidates(%{executable_path: "/nowhere/chrome"}, opts) == [
               {"/nowhere/chrome", "The configured browser"},
               {configured, "The configured browser"},
               {context.installed, "Chromium"},
               {context.downloaded, "Google Chrome for Testing"}
             ]
    end

    test "an installed browser wins over the downloaded Chromium", context do
      opts = [installed: [{context.installed, "Chromium"}]] ++ context.opts

      assert ChromeLauncher.resolve(%Config{}, nil, opts) ==
               {:ok, %{path: context.installed, label: "Chromium"}}
    end

    test "with nothing installed, tasks run in the downloaded Chromium", context do
      opts = [installed: [{"/nowhere/Chromium", "Chromium"}]] ++ context.opts

      assert {:ok, found} = ChromeLauncher.resolve(%Config{}, nil, opts)
      assert found == %{path: context.downloaded, label: "Google Chrome for Testing"}
      assert ChromeLauncher.sentence({:ok, found}) == "Tasks use Google Chrome for Testing."
    end

    test "with nothing at all, the refusal and its sentence say so", %{home: home} do
      opts = [installed: [], downloaded: [root: Path.join(home, "empty"), target: "linux-x86_64"]]

      assert {:error, %{code: "chrome_missing"}} =
               missing = ChromeLauncher.resolve(%Config{}, nil, opts)

      assert ChromeLauncher.sentence(missing) == "No Chrome or Chromium is installed."
    end

    # The launcher refuses a configuration it cannot read, so the answer for the
    # browser tasks run in is that refusal, never a browser it would not start.
    test "a refused configuration is answered with its own sentence" do
      assert {:error, error} = refused = ChromeLauncher.resolve_default(max_tabs: 0)

      assert error.code == "invalid_config"
      assert ChromeLauncher.sentence(refused) == "max_tabs must be a positive integer"
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

  describe "launch_args/3" do
    # WebMCP is an experimental feature name, so a site that registers its tools
    # only when the native API exists is invisible without this flag. Chrome
    # ignores a feature name it does not know, so a rename degrades to
    # `webmcp_unavailable` on those sites and breaks nothing else.
    test "asks Chrome to expose the WebMCP API" do
      args = ChromeLauncher.launch_args(@dir, 0, true)

      assert "--enable-features=WebMCP" in args
      # Separate lists: enabling one feature must not drop the disabled ones.
      assert "--disable-features=Translate,MediaRouter" in args
    end

    # Reuse detection matches the --user-data-dir TOKEN, so a flag added to the
    # list must not shift what that comparison sees.
    test "leaves the user-data-dir token reuse detection matches" do
      args = ChromeLauncher.launch_args(@dir, 9_222, false)

      line =
        "4242 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome " <>
          Enum.join(args, " ")

      assert {:ok, 4242} = ChromeLauncher.parse_ps_pid(line, @dir)
    end

    # The managed profile browses pages nobody vetted and keeps the owner's
    # sign-ins for months, so Chrome's phishing check, its Safe Browsing
    # service and its component updates (the certificate revocation list among
    # them) stay on: these are network-benchmarking flags, not a browser's.
    test "leaves Chrome's own protections on" do
      for headless <- [true, false] do
        args = ChromeLauncher.launch_args(@dir, 0, headless)

        refute "--disable-client-side-phishing-detection" in args
        refute "--disable-background-networking" in args
        refute "--disable-component-update" in args
      end
    end
  end

  describe "spawn_plan/4 (the macOS disclaim shim, the Linux memory guard)" do
    @chrome "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    @chrome_args ["--remote-debugging-port=0", "about:blank"]
    @shim "/release/lib/fermix_nif/priv/disclaim"

    test "darwin spawns the disclaim shim with Chrome as its first argument" do
      assert {:ok, {@shim, [@chrome | @chrome_args]}} =
               ChromeLauncher.spawn_plan(@chrome, @chrome_args, {:unix, :darwin}, @shim)
    end

    test "darwin without a built shim refuses loud — never an undisclaimed spawn" do
      assert {:error, error} =
               ChromeLauncher.spawn_plan(@chrome, @chrome_args, {:unix, :darwin}, nil)

      assert error.code == "shim_missing"
    end

    # The memory guard: out of memory, the kernel stops the process with the
    # highest score, which would otherwise be the engine, one large process
    # holding every channel. A process may raise its own score, so the shell
    # raises it and then becomes Chrome, whose every process inherits it.
    test "Linux starts Chrome through a shell that first makes it the kernel's first choice out of memory" do
      for shim <- [nil, @shim] do
        assert {:ok, {"/bin/sh", ["-c", script, "sh", @chrome | @chrome_args]}} =
                 ChromeLauncher.spawn_plan(@chrome, @chrome_args, {:unix, :linux}, shim)

        assert script == ~S(echo 1000 >/proc/self/oom_score_adj && exec "$@")
      end
    end

    test "every other OS spawns Chrome directly, byte-identical to before" do
      for os <- [{:unix, :freebsd}, {:win32, :nt}], shim <- [nil, @shim] do
        assert {:ok, {@chrome, @chrome_args}} =
                 ChromeLauncher.spawn_plan(@chrome, @chrome_args, os, shim)
      end
    end
  end

  if match?({:unix, :darwin}, :os.type()) do
    describe "start/4 on macOS (through the disclaim shim)" do
      test "fails fast with the exit status when Chrome dies before CDP readiness",
           %{home: home} do
        path = Path.join(home, "fake-chrome-exits")
        File.write!(path, "#!/bin/sh\nexit 3\n")
        File.chmod!(path, 0o700)

        {:ok, config} = Config.current(launch_timeout_ms: 5_000, cdp_ready_poll_interval_ms: 20)
        profile = %{mode: :managed, headless: true, cdp_port: :auto, executable_path: path}

        assert {:error, error} = ChromeLauncher.start(config, profile, "owner", "exits")
        assert error.code == "cdp_not_ready"
        # Fail-fast proof: the exit was consumed, not waited out — the timeout
        # path carries no exit_status detail.
        assert error.details["exit_status"] == 3
      end

      test "surfaces a shim exec failure as disclaim_failed", %{home: home} do
        path = Path.join(home, "fake-chrome-not-executable")
        File.write!(path, "not a binary")
        File.chmod!(path, 0o644)

        {:ok, config} = Config.current(launch_timeout_ms: 5_000, cdp_ready_poll_interval_ms: 20)
        profile = %{mode: :managed, headless: true, cdp_port: :auto, executable_path: path}

        assert {:error, error} = ChromeLauncher.start(config, profile, "owner", "noexec")
        assert error.code == "disclaim_failed"
        assert error.details["exit_status"] == 72
        assert error.details["chrome_output"] =~ "disclaim:"
      end
    end
  end

  if match?({:unix, :linux}, :os.type()) do
    # Each line of a fake Chrome's output arrives within this bound.
    @arrival_ms 10_000

    describe "spawn_plan/4 run on Linux" do
      # The fake prints its pid, its child's score and its arguments, then
      # waits for its input to close, so its pid can be read while it runs.
      test "Chrome runs as the spawned pid, with a score of 1000 and its arguments as given",
           %{home: home} do
        chrome = Path.join(home, "fake chrome")

        File.write!(chrome, """
        #!/bin/sh
        echo "$$"
        cat /proc/self/oom_score_adj
        printf '%s\\n' "$@"
        read -r _closed || true
        """)

        File.chmod!(chrome, 0o700)
        args = ["--user-data-dir=#{home}/profile with a space", "about:blank"]

        {:ok, {target, spawn_args}} =
          ChromeLauncher.spawn_plan(chrome, args, {:unix, :linux}, nil)

        port = Port.open({:spawn_executable, target}, [:binary, {:args, spawn_args}])
        {:os_pid, os_pid} = Port.info(port, :os_pid)

        assert read_lines(port, 4, "") == [Integer.to_string(os_pid), "1000" | args]
        Port.close(port)
      end
    end

    defp read_lines(port, count, received) do
      lines = String.split(received, "\n", trim: true)
      if length(lines) >= count, do: lines, else: read_more(port, count, received)
    end

    defp read_more(port, count, received) do
      receive do
        {^port, {:data, data}} -> read_lines(port, count, received <> data)
      after
        @arrival_ms -> flunk("the fake Chrome printed #{inspect(received)} and then nothing")
      end
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

  defp install_chromium(root, revision) do
    dir = Path.join(root, revision)
    executable = Path.join([dir, "chrome-linux64", "chrome"])
    File.mkdir_p!(Path.dirname(executable))
    File.write!(executable, "#!/bin/sh\n")
    File.write!(Path.join(dir, "INSTALLATION_COMPLETE"), "")
    executable
  end

  defp fake_browser(home, name) do
    path = Path.join([home, "bin", name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\n")
    path
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
