defmodule Fermix.CLI.BrowserBridgeTest do
  # The pump and the two verbs that install it, against a throwaway home, a
  # throwaway browser directory, and a stand-in daemon on a throwaway socket.
  # Nothing here touches a real browser, a real NativeMessagingHosts directory,
  # or a real daemon.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.BrowserBridgeCommand
  alias Fermix.CLI.BrowserBridgeTest.HeldOpenIO
  alias Fermix.CLI.BrowserCommand
  alias FermixCore.Browser.Bridge.Grants
  alias FermixCore.Browser.Bridge.HostManifest
  alias FermixCore.Browser.Bridge.Supervisor, as: BridgeSupervisor
  alias FermixTestSupport.SafeRm

  @origin "chrome-extension://abcdefghijklmnopabcdefghijklmnop/"
  @extension_id "abcdefghijklmnopabcdefghijklmnop"

  setup do
    home = SafeRm.make_tmp_dir!("browser-bridge")
    base = Path.join(home, "browsers")
    File.mkdir_p!(base)

    # Short on purpose: a Unix socket address is capped around 104 bytes.
    socket_path =
      Path.join(System.tmp_dir!(), "fermix-pump-#{System.unique_integer([:positive])}.sock")

    on_exit(fn ->
      SafeRm.rm(socket_path)
      SafeRm.rm_rf!(home)
    end)

    %{home: home, base: base, socket_path: socket_path, opts: manifest_opts(home, base)}
  end

  defp manifest_opts(home, base) do
    [base: base, os: :darwin, fermix_home: home, fermix_path: launcher()]
  end

  # A real, existing executable so `status` can report a launcher that is there;
  # nothing ever runs it.
  defp launcher, do: "/bin/echo"

  # ── the host manifest and its wrapper ──────────────────────────────────────

  test "install writes the wrapper and the manifest, and names both", ctx do
    output =
      capture_io(fn ->
        assert 0 =
                 BrowserCommand.run(
                   ["bridge", "install", "--browser", "chrome", "--extension-id", @extension_id],
                   ctx.opts ++ [socket_path: ctx.socket_path]
                 )
      end)

    {:ok, manifest} = HostManifest.manifest_path("chrome", ctx.opts)
    wrapper = HostManifest.wrapper_path("chrome", ctx.opts)

    assert output =~ manifest
    assert output =~ wrapper
    assert output =~ "click it on the tab you want Fermix to use"

    assert %{
             "name" => "ai.fermix.bridge",
             "type" => "stdio",
             "path" => ^wrapper,
             "allowed_origins" => [@origin]
           } = Jason.decode!(File.read!(manifest))

    script = File.read!(wrapper)
    assert script =~ "exec '#{launcher()}' browser-bridge --manifest '#{manifest}'"
    assert script =~ "FERMIX_HOME='#{ctx.home}'"
    assert File.stat!(wrapper).mode |> Bitwise.band(0o777) == 0o700

    assert manifest =~ "Google/Chrome/NativeMessagingHosts"
  end

  # macOS and Linux put the manifest in different places and the install has to
  # know which — a manifest in the wrong directory is never read and never
  # errors. Path computation only: nothing here touches a real directory.
  test "each browser and OS has its own manifest directory" do
    for {os, expected} <- [
          {:darwin, "Library/Application Support/Google/Chrome/NativeMessagingHosts"},
          {:linux, ".config/google-chrome/NativeMessagingHosts"}
        ] do
      assert {:ok, path} = HostManifest.manifest_path("chrome", os: os)
      assert path =~ expected
      assert Path.basename(path) == "ai.fermix.bridge.json"
    end

    for browser <- HostManifest.browsers() do
      assert {:ok, darwin} = HostManifest.manifest_path(browser, os: :darwin)
      assert {:ok, linux} = HostManifest.manifest_path(browser, os: :linux)
      refute darwin == linux
    end

    assert {:error, {:unsupported_browser, "safari"}} = HostManifest.manifest_path("safari")
    assert {:error, {:unsupported_os, :win32}} = HostManifest.manifest_path("chrome", os: :win32)
  end

  test "install refuses an id that is not an extension id", ctx do
    output =
      capture_io(:stderr, fn ->
        assert 1 =
                 BrowserCommand.run(
                   ["bridge", "install", "--browser", "chrome", "--extension-id", "nope"],
                   ctx.opts
                 )
      end)

    assert output =~ "not an extension id"
    {:ok, manifest} = HostManifest.manifest_path("chrome", ctx.opts)
    refute File.exists?(manifest)
  end

  test "install refuses a browser it has no directory for", ctx do
    output =
      capture_io(:stderr, fn ->
        assert 1 =
                 BrowserCommand.run(
                   ["bridge", "install", "--browser", "safari", "--extension-id", @extension_id],
                   ctx.opts
                 )
      end)

    assert output =~ "--browser must be one of chrome, chromium, brave, edge."
  end

  test "status reports each browser, the launcher, and an unreachable daemon", ctx do
    install!(ctx)

    output =
      capture_io(fn ->
        assert 0 =
                 BrowserCommand.run(
                   ["bridge", "status"],
                   ctx.opts ++ [socket_path: ctx.socket_path]
                 )
      end)

    assert output =~ "chrome: installed"
    assert output =~ "(present)"
    assert output =~ @origin
    assert output =~ "chromium: not installed"
    assert output =~ "brave: not installed"
    assert output =~ "edge: not installed"
    assert output =~ "Daemon: not reachable"
  end

  test "status says so when the launcher the manifest names is gone", ctx do
    install!(ctx, fermix_path: Path.join([ctx.home, "bin", "gone"]))

    output =
      capture_io(fn ->
        assert 0 =
                 BrowserCommand.run(
                   ["bridge", "status", "--browser", "chrome"],
                   ctx.opts ++ [socket_path: ctx.socket_path]
                 )
      end)

    assert output =~ "MISSING"
    # The wrapper itself is still there; it is the fermix it execs that is gone,
    # which is what a `brew upgrade` or an uninstall does to an install.
    assert output =~ "Launcher: #{HostManifest.wrapper_path("chrome", ctx.opts)} (present)"
  end

  test "uninstall removes both files, and says so when there is nothing to remove", ctx do
    install!(ctx)
    {:ok, manifest} = HostManifest.manifest_path("chrome", ctx.opts)

    capture_io(fn ->
      assert 0 = BrowserCommand.run(["bridge", "uninstall", "--browser", "chrome"], ctx.opts)
    end)

    refute File.exists?(manifest)
    refute File.exists?(HostManifest.wrapper_path("chrome", ctx.opts))

    output =
      capture_io(fn ->
        assert 0 = BrowserCommand.run(["bridge", "uninstall", "--browser", "chrome"], ctx.opts)
      end)

    assert output =~ "Nothing to remove"
  end

  test "an unknown subcommand is a usage error", ctx do
    capture_io(:stderr, fn ->
      assert 2 = BrowserCommand.run(["bridge", "reinstall"], ctx.opts)
      assert 2 = BrowserCommand.run(["nonsense"], ctx.opts)
    end)
  end

  defp install!(ctx, overrides \\ []) do
    opts = Keyword.merge(ctx.opts, overrides)

    capture_io(fn ->
      assert 0 =
               BrowserCommand.run(
                 ["bridge", "install", "--browser", "chrome", "--extension-id", @extension_id],
                 opts
               )
    end)
  end

  # ── the pump ───────────────────────────────────────────────────────────────

  test "the pump refuses an origin the installed manifest does not list", ctx do
    install!(ctx)
    {:ok, manifest} = HostManifest.manifest_path("chrome", ctx.opts)

    {status, err} =
      run_pump(
        ["--manifest", manifest, "chrome-extension://ponmlkjihgfedcbaponmlkjihgfedcba/"],
        ""
      )

    assert status == 1
    assert err =~ "is not listed in"
    assert err =~ "fermix browser bridge install"
  end

  test "the pump refuses to start with no manifest argument" do
    {status, err} = run_pump(["chrome-extension://whatever/"], "")
    assert status == 2
    assert err =~ "usage: fermix browser-bridge"
  end

  test "a message from the browser reaches the daemon, however large", ctx do
    install!(ctx)
    {:ok, manifest} = HostManifest.manifest_path("chrome", ctx.opts)
    daemon = start_daemon(ctx.socket_path)

    small = Jason.encode!(%{"type" => "hello", "protocol" => 1})
    # Over the 64 KiB a single read might have stopped at, and over the frame
    # size a line-oriented reader would have mangled.
    large =
      Jason.encode!(%{"type" => "grant", "tab_id" => 1, "title" => String.duplicate("t", 90_000)})

    {status, _err} =
      run_pump(["--manifest", manifest, @origin], native(small) <> native(large),
        socket_path: ctx.socket_path
      )

    assert status == 0
    assert_receive {:daemon_frame, ^small}, 2_000
    assert_receive {:daemon_frame, ^large}, 2_000
    stop_daemon(daemon)
  end

  test "a message from the daemon reaches the browser in native framing", ctx do
    install!(ctx)
    {:ok, manifest} = HostManifest.manifest_path("chrome", ctx.opts)
    reply = Jason.encode!(%{"type" => "hello_ack", "protocol" => 1})
    daemon = start_daemon(ctx.socket_path, greeting: reply)

    # stdin is held open, as Chrome holds it: the pump is still running while
    # the assertion is made, so nothing races the reader reaching EOF.
    {:ok, stdin} = HeldOpenIO.start_link()
    {:ok, stdout} = StringIO.open("")

    pump =
      Task.async(fn ->
        BrowserBridgeCommand.run(["--manifest", manifest, @origin],
          stdin: stdin,
          stdout: stdout,
          stderr: stdout,
          socket_path: ctx.socket_path
        )
      end)

    assert eventually(fn -> elem(StringIO.contents(stdout), 1) == native(reply) end),
           "the daemon's frame did not reach stdout: #{inspect(StringIO.contents(stdout))}"

    HeldOpenIO.close(stdin)
    assert Task.await(pump, 5_000) == 0
    stop_daemon(daemon)
  end

  test "a truncated message is refused rather than half-forwarded", ctx do
    install!(ctx)
    {:ok, manifest} = HostManifest.manifest_path("chrome", ctx.opts)
    daemon = start_daemon(ctx.socket_path)

    # A length header promising 64 bytes with 5 behind it: the browser died
    # mid-write, and half a JSON object is not a message.
    truncated = <<64::unsigned-little-32>> <> "{\"ty"

    {status, err} =
      run_pump(["--manifest", manifest, @origin], truncated, socket_path: ctx.socket_path)

    assert status == 1
    assert err =~ "of a 64-byte message"
    refute_receive {:daemon_frame, _frame}, 200
    stop_daemon(daemon)
  end

  test "a length header the browser never finished is refused", ctx do
    install!(ctx)
    {:ok, manifest} = HostManifest.manifest_path("chrome", ctx.opts)
    daemon = start_daemon(ctx.socket_path)

    {status, err} =
      run_pump(["--manifest", manifest, @origin], <<1, 2>>, socket_path: ctx.socket_path)

    assert status == 1
    assert err =~ "of a 4-byte length header"
    stop_daemon(daemon)
  end

  test "the pump says the daemon is not running rather than hanging", ctx do
    install!(ctx)
    {:ok, manifest} = HostManifest.manifest_path("chrome", ctx.opts)

    {status, err} =
      run_pump(["--manifest", manifest, @origin], "", socket_path: ctx.socket_path)

    assert status == 1
    assert err =~ "the Fermix daemon is not running"
    assert err =~ "fermix run"
  end

  # ── the pump and the real listener, joined ────────────────────────────────

  # The one seam neither side's own test reaches: the real pump re-framing native
  # messaging into the real `Bridge.Endpoint` and its real `Peer`. It needs a
  # stdin that stays OPEN — a pump whose stdin ends closes the connection, and a
  # closed connection correctly takes its grants with it — so the device below is
  # a pipe a writer is still holding, which is what Chrome gives the host.
  test "the real pump's frames are understood by the real peer", ctx do
    start_supervised!(
      {BridgeSupervisor, socket_path: ctx.socket_path, name: nil, endpoint_name: nil},
      id: :join_bridge
    )

    grants = Process.whereis(Grants)

    install!(ctx)
    {:ok, manifest} = HostManifest.manifest_path("chrome", ctx.opts)
    {:ok, stdin} = HeldOpenIO.start_link()
    {:ok, stdout} = StringIO.open("")

    pump =
      Task.async(fn ->
        BrowserBridgeCommand.run(["--manifest", manifest, @origin],
          stdin: stdin,
          stdout: stdout,
          stderr: stdout,
          socket_path: ctx.socket_path
        )
      end)

    HeldOpenIO.write(
      stdin,
      native(Jason.encode!(%{type: "hello", protocol: 1, browser: "chrome"}))
    )

    HeldOpenIO.write(
      stdin,
      native(
        Jason.encode!(%{type: "grant", tab_id: 4242, url: "https://example.com", title: "P"})
      )
    )

    assert eventually(fn -> Grants.summary(grants) == %{extensions: 1, tabs: 1} end),
           "the real peer did not read the pump's frames: #{inspect(Grants.summary(grants))}"

    expected = native(Jason.encode!(%{type: "hello_ack", protocol: 1}))

    assert eventually(fn -> elem(StringIO.contents(stdout), 1) == expected end),
           "the ack did not come back in native framing: #{inspect(StringIO.contents(stdout))}"

    HeldOpenIO.close(stdin)
    assert Task.await(pump, 5_000) == 0
  end

  defp eventually(check, attempts \\ 60) do
    cond do
      check.() -> true
      attempts > 0 -> Process.sleep(25) && eventually(check, attempts - 1)
      true -> false
    end
  end

  # An Erlang io device that behaves like a pipe somebody is still holding open:
  # a read waits for bytes instead of answering `:eof`, and only `close/1` ends
  # the stream. `StringIO` cannot model this — it answers `:eof` the moment its
  # content runs out, which is a writer that has already gone.
  defmodule HeldOpenIO do
    def start_link,
      do: {:ok, spawn_link(fn -> loop(%{buffer: "", waiting: nil, closed: false}) end)}

    def write(pid, data), do: send(pid, {:feed, data})
    def close(pid), do: send(pid, :close)

    defp loop(state) do
      receive do
        {:io_request, from, ref, request} ->
          loop(serve(request, from, ref, state))

        {:feed, data} ->
          loop(answer(%{state | buffer: state.buffer <> data}))

        :close ->
          loop(answer(%{state | closed: true}))
      end
    end

    defp serve({:get_chars, _encoding, _prompt, count}, from, ref, state) do
      answer(%{state | waiting: {from, ref, count}})
    end

    defp serve({:setopts, _opts}, from, ref, state) do
      send(from, {:io_reply, ref, :ok})
      state
    end

    defp serve(_other, from, ref, state) do
      send(from, {:io_reply, ref, {:error, :enotsup}})
      state
    end

    defp answer(%{waiting: nil} = state), do: state

    defp answer(%{waiting: {from, ref, count}} = state) do
      cond do
        byte_size(state.buffer) >= count ->
          <<chunk::binary-size(count), rest::binary>> = state.buffer
          send(from, {:io_reply, ref, chunk})
          %{state | buffer: rest, waiting: nil}

        state.closed ->
          send(from, {:io_reply, ref, eof_or_partial(state.buffer)})
          %{state | buffer: "", waiting: nil}

        true ->
          state
      end
    end

    defp eof_or_partial(""), do: :eof
    defp eof_or_partial(partial), do: partial
  end

  defp native(body), do: <<byte_size(body)::unsigned-little-32>> <> body

  defp run_pump(argv, stdin, opts \\ []) do
    {:ok, input} = StringIO.open(stdin)
    {:ok, output} = StringIO.open("")
    {:ok, errors} = StringIO.open("")

    status =
      BrowserBridgeCommand.run(
        argv,
        Keyword.merge(opts, stdin: input, stdout: output, stderr: errors)
      )

    {_in, written} = StringIO.contents(output)
    send(self(), {:pump_stdout, written})
    {_err_in, err} = StringIO.contents(errors)
    {status, err}
  end

  # A stand-in daemon: it accepts one connection, optionally greets, and reports
  # every frame it receives to the test process.
  defp start_daemon(path, opts \\ []) do
    reporter = self()

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        {:active, false},
        {:ifaddr, {:local, path}},
        {:packet, 4},
        {:reuseaddr, true}
      ])

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 5_000)
        greet(socket, Keyword.get(opts, :greeting))
        collect(socket, reporter)
      end)

    %{listen: listen, pid: pid, path: path}
  end

  defp greet(_socket, nil), do: :ok
  defp greet(socket, frame), do: :ok = :gen_tcp.send(socket, frame)

  defp collect(socket, reporter) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, frame} ->
        send(reporter, {:daemon_frame, frame})
        collect(socket, reporter)

      {:error, _reason} ->
        :ok
    end
  end

  defp stop_daemon(daemon) do
    Process.unlink(daemon.pid)
    Process.exit(daemon.pid, :kill)
    :gen_tcp.close(daemon.listen)
    SafeRm.rm(daemon.path)
  end
end
