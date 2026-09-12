defmodule Fermix.CLI.MigrateToAppTest do
  # Mutates `:fermix_core, :launchctl_runner` — the seam the strict bootout uses.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.Migrate.Journal
  alias Fermix.CLI.MigrateToApp
  alias Fermix.CLI.Service.Launchd
  alias Fermix.CLI.Service.Templates
  alias FermixTestSupport.SafeRm

  @unit_relative "Library/LaunchAgents/io.tezra.fermix.plist"
  @brew_program "/opt/homebrew/bin/fermix"

  defmodule AppBuildInfo do
    def app_engine?, do: true
  end

  defmodule StandaloneBuildInfo do
    def app_engine?, do: false
  end

  setup do
    on_exit(fn -> Application.delete_env(:fermix_core, :launchctl_runner) end)
    :ok
  end

  describe "Launchd.bootout/2 (strict)" do
    test "issues exactly one bootout for the unit path and reports success" do
      record_launchctl({"", 0})

      assert Launchd.bootout(:user, "/tmp/io.tezra.fermix.plist") == :ok
      assert_received {:launchctl, ["bootout", domain, "/tmp/io.tezra.fermix.plist"]}
      assert String.starts_with?(domain, "gui/")
      refute_received {:launchctl, _other}
    end

    test "returns a non-zero launchctl exit verbatim instead of swallowing it" do
      record_launchctl({"Boot-out failed: 5: Input/output error", 5})

      assert Launchd.bootout(:user, "/tmp/io.tezra.fermix.plist") ==
               {:error, {:launchctl_failed, 5, "Boot-out failed: 5: Input/output error"}}
    end

    # The swallowing variant stays exactly as it is for install/uninstall; the
    # strict one is additive. If this goes red, the migration's guarantee was
    # bought by changing the uninstall path underneath it.
    test "uninstall/1 still swallows the same failure — the strict variant is additive" do
      record_launchctl({"Boot-out failed: 5: Input/output error", 5})

      assert Launchd.uninstall(%{scope: :user, unit_path: "/tmp/io.tezra.fermix.plist"}) == :ok
    end
  end

  describe "preflight refusals" do
    test "a non-macOS host is refused before any host command runs" do
      world = new_world()
      stderr = refused(world, os: :linux, command_runner: raising_runner())

      assert stderr =~ "macOS"
    end

    test "an app-managed engine has nothing to migrate" do
      world = new_world()
      stderr = refused(world, build_info: AppBuildInfo, command_runner: raising_runner())

      assert stderr =~ "Fermix.app"
    end

    test "a second Fermix.app copy refuses as duplicate_app with both paths" do
      world = new_world()
      File.mkdir_p!(world.canonical_app)
      File.mkdir_p!(world.user_app)

      stderr = refused(world, command_runner: raising_runner())

      assert stderr =~ "duplicate_app"
      assert stderr =~ world.canonical_app
      assert stderr =~ world.user_app
    end

    test "an installed Fermix.app refuses as app_already_installed" do
      world = new_world()
      File.mkdir_p!(world.canonical_app)

      stderr = refused(world, command_runner: raising_runner())

      assert stderr =~ "app_already_installed"
      assert stderr =~ world.canonical_app
    end

    test "a system LaunchDaemon refuses as system_scope and never touches it" do
      world = new_world()
      File.write!(world.system_plist, "<plist/>")

      stderr = refused(world, command_runner: raising_runner())

      assert stderr =~ "system_scope"
      assert stderr =~ world.system_plist
      assert File.exists?(world.system_plist)
    end

    test "no Homebrew formula install refuses before any mutation" do
      world = new_world()
      runner = scripted_runner(%{["list", "--formula", "--versions", "fermix"] => {"", 1}})

      assert refused(world, command_runner: runner) =~ "no_formula_install"
    end

    test "a running brew service refuses as brew_service_running" do
      world = new_world()

      runner =
        scripted_runner(%{
          ["services", "list"] => {"Name    Status  User\nfermix  started sam\n", 0}
        })

      stderr = refused(world, command_runner: runner)

      assert stderr =~ "brew_service_running"
      assert stderr =~ "started"
    end

    test "a fermix on PATH owned by neither brew nor the app refuses as foreign_cli_target" do
      world = new_world()

      runner =
        scripted_runner(%{["-a", "fermix"] => {"#{@brew_program}\n/usr/bin/fermix\n", 0}})

      stderr = refused(world, command_runner: runner)

      assert stderr =~ "foreign_cli_target"
      assert stderr =~ "/usr/bin/fermix"
    end

    test "a launch agent whose program is not the brew binary refuses as foreign_service" do
      world = new_world(program: "/opt/other/bin/fermix")

      stderr = refused(world, [])

      assert stderr =~ "foreign_service"
      assert stderr =~ "/opt/other/bin/fermix"
      assert File.exists?(world.unit_path), "a foreign unit is never removed"
    end

    test "a recognized unit whose daemon cannot be reached refuses as unreachable_daemon" do
      world = new_world()
      stderr = refused(world, client: constant_client({:error, :not_running}))

      assert stderr =~ "unreachable_daemon"
      assert File.exists?(world.unit_path)
    end

    test "a daemon that answers something other than management v1 is also unreachable" do
      world = new_world()
      stderr = refused(world, client: constant_client({:error, :invalid_management_response}))

      assert stderr =~ "unreachable_daemon"
    end
  end

  describe "dispatch" do
    # The verb is dead code until it is registered, and `main/1` answers an
    # unknown verb with usage, which names no command of its own.
    test "the top-level dispatcher registers the migrate-to-app verb" do
      stderr =
        capture_io(:stderr, fn -> assert Fermix.CLI.main(["migrate-to-app", "-x"]) == 2 end)

      assert stderr =~ "fermix migrate-to-app: unexpected arguments: -x"
      refute stderr =~ "unknown command"
    end
  end

  describe "confirmation" do
    test "without --yes it prints the plan, mutates nothing and exits non-zero" do
      world = new_world()
      install_launchctl(world, {"", 0})

      {status, stdout, _stderr} = run(world, [], [])

      assert status == 2
      assert stdout =~ "--yes"
      assert stdout =~ world.unit_path
      assert File.exists?(world.unit_path)
      refute_received {:launchctl, _args}
      refute_received {:ran, "brew", ["uninstall" | _rest]}
    end
  end

  describe "the migration transaction" do
    test "drains, boots out, removes the unit, journals, swaps the package and launches" do
      world = new_world()
      install_launchctl(world, {"", 0})

      {status, stdout, _stderr} = run(world, ["--yes"], [])

      assert status == 0
      assert_received {:called, "lifecycle.prepare", _params}
      assert_received {:launchctl, ["bootout", _domain, unit_path]}
      assert unit_path == world.unit_path
      refute File.exists?(world.unit_path)
      assert_received {:ran, "brew", ["uninstall", "--formula", "fermix"]}
      assert_received {:ran, "brew", ["install", "--cask", "tezra-io/tap/fermix"]}
      assert_received {:ran, "open", ["-a", app_path]}
      assert app_path == world.canonical_app
      refute_received {:called, "lifecycle.cancel", _params}

      assert {:ok, record} = Journal.read(journal_opts(world))
      assert record["schema_version"] == 1
      assert record["phase"] == "app_launched"
      assert record["fermix_home"] == world.fermix_home
      assert record["source"]["unit_path"] == world.unit_path
      assert stdout =~ "Fermix.app"
    end

    test "the handoff journal is owner-only and leaves no temporary file behind" do
      world = new_world()
      install_launchctl(world, {"", 0})

      {0, _stdout, _stderr} = run(world, ["--yes"], [])

      path = Journal.path(journal_opts(world))
      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o777) == 0o600
      assert Path.wildcard(path <> "*") == [path]
    end

    test "a failed bootout fails the migration, cancels the drain and leaves the unit" do
      world = new_world()
      install_launchctl(world, {"Boot-out failed: 36: Operation now in progress", 36})

      {status, _stdout, stderr} = run(world, ["--yes"], [])

      assert status == 1
      assert stderr =~ "launchctl_failed"
      assert stderr =~ "Boot-out failed"
      assert File.exists?(world.unit_path), "a failed bootout must leave the unit in place"
      assert_received {:called, "lifecycle.cancel", %{"lease_id" => "lease-1"}}
      refute_received {:ran, "brew", ["uninstall" | _rest]}
      assert Journal.read(journal_opts(world)) == {:error, :enoent}
    end

    # `retire/3` boots the unit out before this verification runs, so launchd
    # has already unloaded the job. Reporting "the launch agent is untouched"
    # tells the operator nothing changed while their background service is in
    # fact down until the next login.
    test "a daemon that never exits fails the migration before the unit is removed" do
      world = new_world()
      install_launchctl(world, {"", 0}, unlink_socket: false)
      runner = scripted_runner(%{["-0", "4242"] => {"", 0}})

      {status, _stdout, stderr} = run(world, ["--yes"], command_runner: runner)

      assert status == 1
      assert stderr =~ "4242"
      assert File.exists?(world.unit_path)
      assert_received {:called, "lifecycle.cancel", _params}
      refute_received {:ran, "brew", ["uninstall" | _rest]}

      refute stderr =~ "launch agent is untouched"
      assert stderr =~ "unloaded"
      assert stderr =~ "fermix start"
    end

    test "a unit whose bytes changed after preflight is never removed" do
      world = new_world()
      mutate = fn -> File.write!(world.unit_path, "<plist/>") end
      install_launchctl(world, {"", 0}, on_bootout: mutate)

      {status, _stdout, stderr} = run(world, ["--yes"], [])

      assert status == 1
      assert stderr =~ "changed"
      assert File.exists?(world.unit_path)
      refute_received {:ran, "brew", ["uninstall" | _rest]}
      assert Journal.read(journal_opts(world)) == {:error, :enoent}
    end

    test "a failed brew uninstall fails loud and leaves a recoverable journal" do
      world = new_world()
      install_launchctl(world, {"", 0})

      runner =
        scripted_runner(%{["uninstall", "--formula", "fermix"] => {"Error: no such keg", 1}})

      {status, _stdout, stderr} = run(world, ["--yes"], command_runner: runner)

      assert status == 1
      assert stderr =~ "no such keg"
      refute_received {:ran, "brew", ["install" | _rest]}

      assert {:ok, record} = Journal.read(journal_opts(world))
      assert record["phase"] == "handoff_written"

      # The formula is still installed, so `fermix` is still on PATH and
      # re-running the command is the real next step.
      assert stderr =~ "fermix migrate-to-app --yes"
    end

    # Once `brew uninstall --formula` has succeeded, brew has removed the Cellar
    # tree and the PATH symlink: telling the operator to re-run `fermix` points
    # them at a binary this step just deleted, on an account with no daemon, no
    # launch agent and no app.
    test "a failed cask install names the cask, never the deleted fermix binary" do
      world = new_world()
      install_launchctl(world, {"", 0})

      runner =
        scripted_runner(%{
          ["install", "--cask", "tezra-io/tap/fermix"] => {"Error: download failed", 1}
        })

      {status, _stdout, stderr} = run(world, ["--yes"], command_runner: runner)

      assert status == 1
      assert stderr =~ "download failed"
      assert stderr =~ "brew install --cask tezra-io/tap/fermix"
      refute stderr =~ "re-run `fermix migrate-to-app"

      assert {:ok, record} = Journal.read(journal_opts(world))
      assert record["phase"] == "formula_uninstalled"
    end
  end

  describe "Journal" do
    # M34 §6 pins the journal as "written atomically with fsync". The record is
    # created only after the plist is gone and the daemon is stopped, so it is
    # the sole record of the source home: a rename whose contents never reached
    # the disk leaves a zero-length file that reads as `:invalid_journal`, with
    # the legacy install already dismantled.
    test "the record is flushed to disk before the rename, not just written" do
      world = new_world()
      opts = journal_opts(world)

      assert {:ok, _record} = Journal.write(%{"fermix_home" => world.fermix_home}, opts)
      assert :sync in Journal.write_modes()

      body = File.read!(Journal.path(opts))
      assert byte_size(body) > 0
      assert {:ok, %{"fermix_home" => _home}} = Jason.decode(body)
    end

    test "advance/2 rewrites the phase and keeps the schema, creation time and payload" do
      world = new_world()
      opts = journal_opts(world)

      assert {:ok, written} = Journal.write(%{"fermix_home" => world.fermix_home}, opts)
      assert written["phase"] == "handoff_written"

      assert {:ok, advanced} = Journal.advance("formula_uninstalled", opts)
      assert advanced["phase"] == "formula_uninstalled"
      assert advanced["created_at"] == written["created_at"]
      assert advanced["transaction_id"] == written["transaction_id"]
      assert advanced["fermix_home"] == world.fermix_home
    end

    test "an unknown phase is refused rather than persisted" do
      world = new_world()
      opts = journal_opts(world)
      {:ok, _written} = Journal.write(%{"fermix_home" => world.fermix_home}, opts)

      assert Journal.advance("almost_done", opts) == {:error, {:unknown_phase, "almost_done"}}
    end
  end

  # ── world ────────────────────────────────────────────────────────────────

  defp new_world(opts \\ []) do
    root = SafeRm.make_tmp_dir!("migrate-to-app")
    on_exit(fn -> SafeRm.rm_rf!(root) end)

    home = Path.join(root, "home")
    fermix_home = Path.join(root, "fermix")
    unit_path = Path.join(home, @unit_relative)
    socket_path = Path.join(fermix_home, "daemon.sock")

    File.mkdir_p!(Path.dirname(unit_path))
    File.mkdir_p!(fermix_home)
    File.mkdir_p!(Path.join(root, "Applications"))
    File.write!(unit_path, plist_body(Keyword.get(opts, :program, @brew_program)))
    File.write!(socket_path, "")

    %{
      root: root,
      home: home,
      fermix_home: fermix_home,
      unit_path: unit_path,
      socket_path: socket_path,
      system_plist: Path.join(root, "LaunchDaemons-io.tezra.fermix.plist"),
      canonical_app: Path.join(root, "Applications/Fermix.app"),
      user_app: Path.join(home, "Applications/Fermix.app")
    }
  end

  # Rendered by the same template the installer writes, so the verifier is
  # tested against the real unit rather than a hand-copied approximation.
  defp plist_body(program) do
    Templates.render_darwin_plist(%{
      label: "io.tezra.fermix",
      fermix_path: program,
      service_env: %{"FERMIX_HOME" => "/home/.fermix"},
      log_path: "/home/.fermix/logs/fermix.log"
    })
  end

  defp deps(world, overrides) do
    defaults = [
      build_info: StandaloneBuildInfo,
      os: :darwin,
      home: world.home,
      fermix_home: world.fermix_home,
      system_unit_path: world.system_plist,
      app_paths: [world.canonical_app, world.user_app],
      client: default_client(),
      command_runner: scripted_runner(%{}),
      sleep: fn _ms -> :ok end,
      verify_polls: 2
    ]

    Keyword.merge(defaults, overrides)
  end

  defp run(world, argv, overrides) do
    deps = deps(world, overrides)
    parent = self()

    stdout =
      capture_io(fn ->
        stderr =
          capture_io(:stderr, fn ->
            send(parent, {:exit_status, MigrateToApp.run(argv, deps)})
          end)

        send(parent, {:captured_stderr, stderr})
      end)

    assert_received {:exit_status, status}
    assert_received {:captured_stderr, stderr}
    {status, stdout, stderr}
  end

  defp refused(world, overrides) do
    {status, _stdout, stderr} = run(world, ["--yes"], overrides)
    assert status == 1
    stderr
  end

  defp journal_opts(world), do: [home: world.home]

  # ── seams ────────────────────────────────────────────────────────────────

  # `hello` names a live daemon under pid 4242; `lifecycle.prepare` hands back
  # the single lease the transaction releases.
  defp default_client do
    test_pid = self()

    fn method, params, _opts ->
      send(test_pid, {:called, method, params})

      case method do
        "hello" -> {:ok, %{"engine" => %{"pid" => "4242", "product_version" => "0.9.0"}}}
        "lifecycle.prepare" -> {:ok, %{"lease_id" => "lease-1", "expires_at_ms" => 30_000}}
        "lifecycle.cancel" -> {:ok, %{"lease_id" => "lease-1", "status" => "cancelled"}}
        other -> {:error, {:unexpected_method, other}}
      end
    end
  end

  defp constant_client(reply) do
    test_pid = self()

    fn method, params, _opts ->
      send(test_pid, {:called, method, params})
      if method == "hello", do: reply, else: {:ok, %{"lease_id" => "lease-1"}}
    end
  end

  # A healthy macOS world: one brew-owned fermix on PATH, the formula installed,
  # no brew service, and pid 4242 already gone. `overrides` replaces the answer
  # for one exact argv.
  defp scripted_runner(overrides) do
    test_pid = self()

    fn command, args ->
      send(test_pid, {:ran, command, args})
      Map.get_lazy(overrides, args, fn -> default_command(args) end)
    end
  end

  defp default_command(["-a", "fermix"]), do: {"#{@brew_program}\n", 0}
  defp default_command(["--prefix"]), do: {"/opt/homebrew\n", 0}
  defp default_command(["list", "--formula", "--versions", "fermix"]), do: {"fermix 0.9.0\n", 0}
  defp default_command(["services", "list"]), do: {"Name Status User File\n", 0}
  defp default_command(["-0", _pid]), do: {"", 1}
  defp default_command(_args), do: {"", 0}

  defp raising_runner do
    fn command, args ->
      raise "no host command may run here: #{command} #{Enum.join(args, " ")}"
    end
  end

  defp record_launchctl(reply) do
    test_pid = self()

    Application.put_env(:fermix_core, :launchctl_runner, fn "launchctl", args ->
      send(test_pid, {:launchctl, args})
      reply
    end)
  end

  # A faithful launchd: a successful bootout stops the job, so the daemon exits
  # and unlinks its own socket.
  defp install_launchctl(world, reply, opts \\ []) do
    test_pid = self()
    unlink? = Keyword.get(opts, :unlink_socket, true)
    on_bootout = Keyword.get(opts, :on_bootout, fn -> :ok end)

    Application.put_env(:fermix_core, :launchctl_runner, fn "launchctl", args ->
      send(test_pid, {:launchctl, args})
      if reply == {"", 0}, do: bootout_side_effects(world, unlink?, on_bootout)
      reply
    end)
  end

  defp bootout_side_effects(world, unlink?, on_bootout) do
    if unlink?, do: SafeRm.rm!(world.socket_path)
    on_bootout.()
  end
end
