defmodule Fermix.CLI.Service.PackagedTest do
  @moduledoc """
  The packaged Linux service transaction (M38 §4.4, slice EA1 items 5 to 7).

  Every `systemctl` and `loginctl` call, every `hello`, every health probe and
  every sleep is injected, and the binding, the user unit and the installed
  manifest live under a temporary root. Nothing here reaches the host.
  """

  use ExUnit.Case, async: true

  alias Fermix.CLI.Service.Binding
  alias Fermix.CLI.Service.Packaged
  alias FermixCore.Setup.ConfigStore
  alias FermixTestSupport.SafeRm

  @unit "fermix.service"
  @vendor_unit "/usr/lib/systemd/user/fermix.service"

  defmodule PackagedBuildInfo do
    @moduledoc false

    def distribution_identity, do: "linux_package"
    def app_engine?, do: false
    def linux_package?, do: true

    def public_identity do
      %{
        "engine_id" => "fermix-core",
        "product_version" => "1.2.3",
        "build_id" => "release-9",
        "source_commit" => String.duplicate("a", 40),
        "distribution_identity" => "linux_package",
        "artifact_target" => "linux_x86_64",
        "architecture" => "x86_64"
      }
    end
  end

  setup do
    root = SafeRm.make_tmp_dir!("packaged_service")
    on_exit(fn -> SafeRm.rm_rf!(root) end)

    %{
      root: root,
      config_root: Path.join(root, "config"),
      unit_path: Path.join([root, "systemd", "user", @unit]),
      manifest_path: Path.join(root, "engine.json"),
      home: synthetic_home("home"),
      other_home: synthetic_home("other")
    }
  end

  describe "status/1" do
    test "a fresh package reports no binding, no unit and no running engine", context do
      assert {:ok, status} = Packaged.status(opts(context, properties: fresh_properties()))

      assert status["binding"]["state"] == "unbound"
      assert status["unit"]["effective_path"] == @vendor_unit
      assert status["unit"]["vendor"] == true
      assert status["enabled"] == false
      assert status["active"] == false
      assert status["running"] == nil
      assert status["alignment"] == "not_running"
      assert status["installed"]["distribution_identity"] == "linux_package"
      assert status["installed"]["integrity"] == "unreadable"
    end

    test "a bound and running service reports the daemon's own identity", context do
      :ok = Binding.write(context.home, root: context.config_root)
      File.write!(context.manifest_path, Jason.encode!(installed_identity()))

      assert {:ok, status} = Packaged.status(opts(context))

      assert status["binding"] == %{
               "state" => "bound",
               "home" => context.home,
               "reason" => nil
             }

      assert status["running"]["build_id"] == "release-9"
      assert status["alignment"] == "aligned"
      assert status["installed"]["integrity"] == "verified"
      assert status["listener"]["origin"] == "http://127.0.0.1:4030"
    end

    test "hello is asked at the bound home's own socket", context do
      :ok = Binding.write(context.home, root: context.config_root)
      test = self()

      hello = fn socket_path ->
        send(test, {:hello_at, socket_path})
        {:ok, hello()}
      end

      assert {:ok, _status} = Packaged.status(opts(context, hello: hello))
      assert_received {:hello_at, socket_path}
      assert socket_path == Path.join(context.home, "daemon.sock")
    end

    # §4.4.1: an unreachable user manager is a structured error, because
    # "inactive" would send an operator to restart a healthy service.
    test "an unreachable user manager refuses instead of reporting inactive", context do
      opts = opts(context, cmd: unreachable_runner())

      assert Packaged.status(opts) == {:error, :user_manager_unreachable}
    end

    test "a legacy generated unit is reported, never silently adopted", context do
      write_unit(context, legacy_unit(context.home))

      assert {:ok, status} = Packaged.status(opts(context))
      assert status["unit"]["legacy_generated"] == true
      assert status["unit"]["foreign"] == false
    end

    test "a foreign unit and a foreign drop-in are both reported as foreign", context do
      write_unit(context, "[Service]\nExecStart=/usr/bin/somebody-elses-daemon\n")

      assert {:ok, status} = Packaged.status(opts(context))
      assert status["unit"]["foreign"] == true

      SafeRm.rm!(context.unit_path)
      write_drop_in(context, "90-operator.conf", "[Service]\nEnvironment=\"X=1\"\n")

      assert {:ok, second} = Packaged.status(opts(context))
      assert second["unit"]["foreign"] == true
    end

    test "the drop-in this CLI owns is not foreign", context do
      write_drop_in(context, "fermix-observability.conf", "[Service]\n")

      assert {:ok, status} = Packaged.status(opts(context))
      assert status["unit"]["foreign"] == false
    end

    test "a malformed binding carries its sentence and no guessed home", context do
      File.mkdir_p!(Path.dirname(Binding.path(root: context.config_root)))
      File.write!(Binding.path(root: context.config_root), "{not json")

      assert {:ok, status} = Packaged.status(opts(context))
      assert status["binding"]["state"] == "invalid"
      assert status["binding"]["home"] == nil
      assert status["binding"]["reason"] =~ "could not be read"
    end
  end

  describe "install/1" do
    test "a fresh install binds the home, lingers, reloads, resets and enables", context do
      assert {:ok, status} = Packaged.install(opts(context, home: context.home))

      assert Binding.read(root: context.config_root) == {:ok, %{home: context.home}}
      assert status["binding"]["home"] == context.home

      assert_received {:ran, "loginctl", ["show-user", _user, "-p", "Linger", "--value"]}
      assert_received {:ran, "systemctl", ["--user", "daemon-reload"]}
      assert_received {:ran, "systemctl", ["--user", "reset-failed", @unit]}
      assert_received {:ran, "systemctl", ["--user", "enable", "--now", @unit]}
    end

    # The first install on a fresh account resets a unit the manager has never
    # loaded, and systemd answers non-zero saying so. That is nothing to clear,
    # not a refusal — chaining it with `:ok <-` refused every first install
    # (found by installing the real deb on systemd 257).
    test "a reset of a unit nothing has loaded yet does not refuse the install", context do
      opts =
        opts(context,
          home: context.home,
          reset_failed:
            {"Failed to reset-failed fermix.service: Unit fermix.service not loaded.\n", 1}
        )

      assert {:ok, status} = Packaged.install(opts)
      assert status["binding"]["home"] == context.home

      assert_received {:ran, "systemctl", ["--user", "reset-failed", @unit]}
      assert_received {:ran, "systemctl", ["--user", "enable", "--now", @unit]}
    end

    test "a reset refused for any other reason still stops the install", context do
      opts = opts(context, home: context.home, reset_failed: {"Access denied\n", 1})

      assert Packaged.install(opts) == {:error, {:systemctl_failed, 1, "Access denied"}}
      refute_received {:ran, "systemctl", ["--user", "enable" | _rest]}
    end

    test "no unit file is ever written: the package owns the vendor unit", context do
      assert {:ok, _status} = Packaged.install(opts(context, home: context.home))

      refute File.exists?(context.unit_path)
    end

    test "an absent --home keeps the home the binding already names", context do
      :ok = Binding.write(context.home, root: context.config_root)

      assert {:ok, status} = Packaged.install(opts(context))
      assert status["binding"]["home"] == context.home
    end

    test "an invalid home is refused before anything is written", context do
      assert {:error, {:invalid_home, sentence}} =
               Packaged.install(opts(context, home: "relative/home"))

      assert sentence =~ "absolute"
      assert Binding.read(root: context.config_root) == {:error, :missing}
      refute_received {:ran, "systemctl", ["--user", "enable" | _rest]}
    end

    test "moving an active service's home is refused until it is stopped", context do
      :ok = Binding.write(context.home, root: context.config_root)
      other = context.other_home

      assert Packaged.install(opts(context, home: other)) ==
               {:error, {:home_change_refused, context.home}}

      assert Binding.read(root: context.config_root) == {:ok, %{home: context.home}}
    end

    test "an inactive service may be rebound to another home", context do
      :ok = Binding.write(context.home, root: context.config_root)
      other = context.other_home

      assert {:ok, status} =
               Packaged.install(opts(context, home: other, properties: fresh_properties()))

      assert status["binding"]["home"] == other
    end

    # §4.3: linger failure is fatal before enablement. There is no successful
    # activation with failed linger.
    test "a denied linger stops the transaction before the service is enabled", context do
      opts =
        opts(context,
          home: context.home,
          linger_state: {"no\n", 0},
          enable_linger: {"Access denied\n", 1}
        )

      assert Packaged.install(opts) == {:error, {:linger_denied, "Access denied"}}
      refute_received {:ran, "systemctl", ["--user", "enable" | _rest]}
    end

    test "an absent loginctl and an undeterminable account stay distinct", context do
      absent = opts(context, home: context.home, find_executable: fn _n -> nil end)
      nameless = opts(context, home: context.home, username: fn _o -> nil end)

      assert Packaged.install(absent) == {:error, :loginctl_absent}
      assert Packaged.install(nameless) == {:error, :no_identity}
    end

    test "an unreachable user manager refuses the whole transaction", context do
      opts = opts(context, home: context.home, cmd: unreachable_runner())

      assert Packaged.install(opts) == {:error, :user_manager_unreachable}
    end

    # M38 §4.7: the port is persisted through the shared config write, into the
    # home being bound rather than the one this CLI process happens to have.
    test "a port is recorded in the bound home's settings file", context do
      assert {:ok, _status} = Packaged.install(opts(context, home: context.home, port: 4040))

      assert File.read!(Path.join(context.home, "config.toml")) =~ "[fermix_web]\nport = 4040"
      assert ConfigStore.web_port(context.home) == {:ok, 4040}
    end

    # A port outside the bounds refuses before the binding is written, so a
    # rejected transaction leaves nothing half-applied.
    test "a port outside the bounds refuses before anything is written", context do
      assert {:error, {:invalid_port, sentence}} =
               Packaged.install(opts(context, home: context.home, port: 80))

      assert sentence =~ "1024"
      assert Binding.read(root: context.config_root) == {:error, :missing}
      refute File.exists?(Path.join(context.home, "config.toml"))
    end

    test "a foreign unit refuses and names the path it will not touch", context do
      write_unit(context, "[Service]\nExecStart=/usr/bin/somebody-elses-daemon\n")

      assert Packaged.install(opts(context, home: context.home)) ==
               {:error, {:foreign_unit, context.unit_path}}

      assert File.read!(context.unit_path) =~ "somebody-elses-daemon"
    end

    test "a foreign drop-in refuses and names the drop-in, not the unit", context do
      drop_in = write_drop_in(context, "90-operator.conf", "[Service]\nEnvironment=\"X=1\"\n")

      assert Packaged.install(opts(context, home: context.home)) ==
               {:error, {:foreign_unit, drop_in}}
    end
  end

  describe "install/1 verification" do
    test "the service is verified through its own socket and its own web address",
         context do
      test = self()

      probe = fn origin ->
        send(test, {:probed, origin})
        :ok
      end

      assert {:ok, _status} =
               Packaged.install(opts(context, home: context.home, health_probe: probe))

      assert_received {:probed, "http://127.0.0.1:4030"}
    end

    test "a daemon that never answers times out rather than claiming success", context do
      opts =
        opts(context,
          home: context.home,
          hello: fn _socket -> {:error, :not_running} end,
          poll_attempts: 3
        )

      assert Packaged.install(opts) == {:error, :activation_timeout}
    end

    test "polling waits between attempts and stops at the first good answer", context do
      test = self()
      counter = :counters.new(1, [])

      hello = fn _socket ->
        :counters.add(counter, 1, 1)
        if :counters.get(counter, 1) < 3, do: {:error, :not_running}, else: {:ok, hello()}
      end

      opts =
        opts(context,
          home: context.home,
          hello: hello,
          sleep: fn ms -> send(test, {:slept, ms}) end
        )

      assert {:ok, _status} = Packaged.install(opts)
      assert :counters.get(counter, 1) == 3
      assert_received {:slept, 500}
    end

    # A daemon of another distribution answering at that socket is not this
    # service: adopting it would report somebody else's engine as installed.
    test "a foreign daemon answering at the bound socket is not an activation", context do
      foreign = put_in(hello(), ["engine", "distribution_identity"], "standalone")

      opts =
        opts(context, home: context.home, hello: fn _s -> {:ok, foreign} end, poll_attempts: 2)

      assert Packaged.install(opts) == {:error, :activation_timeout}
    end

    test "a running daemon whose web address is dead is a named failure", context do
      opts =
        opts(context, home: context.home, health_probe: fn _origin -> {:error, :econnrefused} end)

      assert Packaged.install(opts) == {:error, :health_unavailable}
    end

    # The daemon binds its control socket before its web endpoint — a measured
    # 57-65 ms warm and 315 ms cold — so the address that answered `hello` is
    # not listening yet. One unretried request lands in that window, and
    # refused one healthy install in four on ubuntu:26.04.
    test "a web address that answers late is waited for, not refused", context do
      test = self()
      counter = :counters.new(1, [])

      probe = fn origin ->
        :counters.add(counter, 1, 1)
        send(test, {:probed, origin})
        if :counters.get(counter, 1) < 3, do: {:error, :econnrefused}, else: :ok
      end

      opts =
        opts(context,
          home: context.home,
          health_probe: probe,
          sleep: fn ms -> send(test, {:slept, ms}) end
        )

      assert {:ok, _status} = Packaged.install(opts)
      assert :counters.get(counter, 1) == 3
      assert_received {:probed, "http://127.0.0.1:4030"}
      assert_received {:slept, 500}
    end

    test "an address that never answers refuses at the bound, having tried it", context do
      counter = :counters.new(1, [])

      probe = fn _origin ->
        :counters.add(counter, 1, 1)
        {:error, :econnrefused}
      end

      opts =
        opts(context,
          home: context.home,
          health_probe: probe,
          poll_attempts: 40,
          health_attempts: 6
        )

      assert Packaged.install(opts) == {:error, :health_unavailable}
      assert :counters.get(counter, 1) == 6
    end

    # `health_unavailable` says the address did not answer, so it is never
    # reported without asking — even when the hello wait spent the budget.
    test "a hello that spends the whole budget still buys one probe", context do
      counter = :counters.new(1, [])

      hello = fn _socket ->
        if :counters.get(counter, 1) == 0, do: {:ok, hello()}, else: {:error, :not_running}
      end

      probe = fn _origin ->
        :counters.add(counter, 1, 1)
        {:error, :econnrefused}
      end

      opts =
        opts(context, home: context.home, hello: hello, health_probe: probe, poll_attempts: 1)

      assert Packaged.install(opts) == {:error, :health_unavailable}
      assert :counters.get(counter, 1) == 1
    end

    # §4.1 sets one 90-second ceiling for the whole transaction, so the health
    # wait spends what the hello wait left rather than stacking a second
    # budget on top of it.
    test "the health wait draws from the budget the hello wait left", context do
      hellos = :counters.new(1, [])
      probes = :counters.new(1, [])

      hello = fn _socket ->
        :counters.add(hellos, 1, 1)
        if :counters.get(hellos, 1) < 3, do: {:error, :not_running}, else: {:ok, hello()}
      end

      probe = fn _origin ->
        :counters.add(probes, 1, 1)
        {:error, :econnrefused}
      end

      opts =
        opts(context,
          home: context.home,
          hello: hello,
          health_probe: probe,
          poll_attempts: 5,
          health_attempts: 20
        )

      assert Packaged.install(opts) == {:error, :health_unavailable}
      # Three of the five attempts went to `hello`; the health wait got the
      # two that were left, not twenty of its own.
      assert :counters.get(probes, 1) == 2
    end

    # A daemon that published no origin will not publish one by being asked
    # again, so this refuses on the spot rather than spending the budget.
    test "a daemon that publishes no web address refuses without polling", context do
      counter = :counters.new(1, [])

      probe = fn _origin ->
        :counters.add(counter, 1, 1)
        {:error, :no_origin}
      end

      opts =
        opts(context,
          home: context.home,
          hello: fn _socket -> {:ok, put_in(hello(), ["setup", "origin"], nil)} end,
          health_probe: probe
        )

      assert Packaged.install(opts) == {:error, :health_unavailable}
      assert :counters.get(counter, 1) == 0
    end
  end

  describe "install/1 legacy migration" do
    test "the legacy unit's home becomes the binding and the unit is removed", context do
      write_unit(context, legacy_unit(context.home))

      assert {:ok, status} = Packaged.install(opts(context))

      assert Binding.read(root: context.config_root) == {:ok, %{home: context.home}}
      assert status["binding"]["home"] == context.home
      refute File.exists?(context.unit_path)
      assert_received {:ran, "systemctl", ["--user", "daemon-reload"]}
    end

    test "a home carrying spaces and percent characters survives the migration", context do
      home = synthetic_home("my 100% home")
      write_unit(context, legacy_unit(home))

      assert {:ok, _status} = Packaged.install(opts(context))

      assert Binding.read(root: context.config_root) == {:ok, %{home: home}}
    end

    test "observability values move into the drop-in this CLI owns", context do
      write_unit(context, legacy_unit(context.home, observability()))

      assert {:ok, _status} = Packaged.install(opts(context))

      drop_in = Path.join([context.unit_path <> ".d", "fermix-observability.conf"])
      contents = File.read!(drop_in)

      assert contents =~ "[Service]"
      assert contents =~ ~s(Environment="FERMIX_OPIK_ENABLED=1")
      assert contents =~ ~s(Environment="FERMIX_OPIK_BASE_URL=http://localhost:5173/api")
      assert contents =~ ~s(Environment="FERMIX_TRACE_CONTENT=0")
      # The unit's own PATH and home are install-time values the packaged
      # engine now derives itself; carrying them forward would pin one machine's.
      refute contents =~ "FERMIX_HOME"
      refute contents =~ "Environment=\"PATH"
    end

    test "a legacy unit with nothing to carry writes no drop-in", context do
      write_unit(context, legacy_unit(context.home))

      assert {:ok, _status} = Packaged.install(opts(context))
      refute File.exists?(context.unit_path <> ".d")
    end

    test "an explicit --home wins over the legacy unit's own home", context do
      write_unit(context, legacy_unit(synthetic_home("old")))
      chosen = context.other_home

      assert {:ok, _status} = Packaged.install(opts(context, home: chosen))

      assert Binding.read(root: context.config_root) == {:ok, %{home: chosen}}
    end

    # Retrying an interrupted migration must reach the same home, never another.
    test "the migration is idempotent when it is retried", context do
      write_unit(context, legacy_unit(context.home, observability()))

      assert {:ok, _first} = Packaged.install(opts(context))
      assert {:ok, second} = Packaged.install(opts(context))

      assert second["binding"]["home"] == context.home
      assert Binding.read(root: context.config_root) == {:ok, %{home: context.home}}
    end
  end

  describe "uninstall/1" do
    test "disables and stops the unit, and keeps the binding", context do
      :ok = Binding.write(context.home, root: context.config_root)

      assert Packaged.uninstall(opts(context)) == :ok

      assert_received {:ran, "systemctl", ["--user", "disable", "--now", @unit]}
      assert Binding.read(root: context.config_root) == {:ok, %{home: context.home}}
    end

    test "the vendor unit is never removed", context do
      assert Packaged.uninstall(opts(context)) == :ok
      refute_received {:ran, "systemctl", ["--user", "daemon-reload"]}
    end

    test "an unreachable user manager is reported, not swallowed", context do
      assert Packaged.uninstall(opts(context, cmd: unreachable_runner())) ==
               {:error, :user_manager_unreachable}
    end
  end

  # The predicate `fermix setup`'s activation and the published service state
  # both read. It has one answer, so every condition that is not "bound and
  # effective" is false; the reasoned refusal for the same host is `status/1`'s.
  describe "installed?/1" do
    test "true only when a home is bound and the package's unit is effective", context do
      refute Packaged.installed?(opts(context))

      :ok = Binding.write(context.home, root: context.config_root)

      assert Packaged.installed?(opts(context))
    end

    test "false when another unit shadows the package's own", context do
      :ok = Binding.write(context.home, root: context.config_root)

      refute Packaged.installed?(opts(context, properties: shadowed_properties()))
    end

    test "false when there is no user service manager to ask", context do
      :ok = Binding.write(context.home, root: context.config_root)

      refute Packaged.installed?(opts(context, cmd: unreachable_runner()))
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  # A service home is recorded in the binding and never created by any of these
  # transactions, so it only has to be an absolute path that fits the OS socket
  # address. A deep temporary directory does not.
  defp synthetic_home(name) do
    "/tmp/fermix-test-#{System.unique_integer([:positive])}-#{name}"
  end

  # M38 §4.1. The lease is never committed — systemd owns the termination signal
  # — and it is cancelled only while the generation that granted it is alive.
  describe "restart/1" do
    setup context do
      :ok = Binding.write(context.home, root: context.config_root)
      :ok
    end

    test "replaces the generation and reports the new one", context do
      opts = restart_opts(context, pids: ["100", "100", "412"])

      assert {:ok, result} = Packaged.restart(opts)

      assert result == %{
               "previous_pid" => "100",
               "pid" => "412",
               "alignment" => "aligned"
             }

      assert_receive {:called, "lifecycle.prepare", %{}}
      assert_receive {:ran, "systemctl", ["--user", "reset-failed", @unit]}
      assert_receive {:ran, "systemctl", ["--user", "restart", @unit]}
    end

    # A package upgrade rewrites the vendor unit, and nothing running as root
    # can reload a user manager: the postinstall has no session bus for this
    # account. So the owner's own restart is the first moment anything running
    # as the owner can do it, and until it does, systemd starts the unit text it
    # last read -- which on this upgrade is the one without the launcher.
    test "reloads the manager first when the unit on disk has not been read", context do
      opts =
        restart_opts(context, pids: ["100", "412"], properties: needs_reload_properties())

      assert {:ok, _result} = Packaged.restart(opts)

      assert_receive {:ran, "systemctl", ["--user", "daemon-reload"]}
      assert_receive {:ran, "systemctl", ["--user", "reset-failed", @unit]}
      assert_receive {:ran, "systemctl", ["--user", "restart", @unit]}
    end

    test "does not reload a manager that is already current", context do
      assert {:ok, _result} = Packaged.restart(restart_opts(context, pids: ["100", "412"]))

      refute_received {:ran, "systemctl", ["--user", "daemon-reload"]}
    end

    # Never swallowed: a restart that silently kept the stale unit is exactly
    # the failure this whole change exists to end.
    test "a refused reload fails the restart and names it", context do
      opts =
        restart_opts(context,
          pids: ["100", "412"],
          properties: needs_reload_properties(),
          daemon_reload: {"Access denied\n", 1}
        )

      assert {:error, reason} = Packaged.restart(opts)
      assert inspect(reason) =~ "Access denied"

      refute_received {:ran, "systemctl", ["--user", "restart", @unit]}
    end

    # `lifecycle.commit` means "stop yourself", and asking for that while systemd
    # is restarting the unit is the one thing §4.1 forbids.
    test "never commits the lease it took", context do
      assert {:ok, _result} = Packaged.restart(restart_opts(context, pids: ["100", "412"]))

      refute_received {:called, "lifecycle.commit", _params}
      refute_received {:called, "lifecycle.cancel", _params}
    end

    # The same pid is the old process still serving: the restart job answers
    # before the VM stops.
    test "the same pid answering is not a new generation", context do
      opts = restart_opts(context, pids: ["100", "100", "100", "100", "100"])

      assert Packaged.restart(opts) == {:error, :activation_timeout}
    end

    test "a service manager that refuses the restart cancels the lease", context do
      opts =
        restart_opts(context,
          pids: ["100"],
          cmd: fn
            "systemctl", ["--user", "restart", _unit] -> {"Job failed.", 1}
            "systemctl", ["--user", "show" | _rest] -> {active_properties(), 0}
            "systemctl", _args -> {"", 0}
            _executable, _args -> {"", 0}
          end
        )

      assert {:error, {:systemctl_failed, 1, "Job failed."}} = Packaged.restart(opts)
      assert_receive {:called, "lifecycle.cancel", %{"lease_id" => "lease-1"}}
    end

    test "a failed budget reset cancels the lease before anything is restarted", context do
      opts =
        restart_opts(context,
          pids: ["100"],
          cmd: fn
            "systemctl", ["--user", "reset-failed", _unit] ->
              {"Access denied", 1}

            "systemctl", ["--user", "restart", _unit] ->
              raise "the restart must not be issued after a failed reset"

            "systemctl", ["--user", "show" | _rest] ->
              {active_properties(), 0}

            _executable, _args ->
              {"", 0}
          end
        )

      assert {:error, {:systemctl_failed, 1, "Access denied"}} = Packaged.restart(opts)
      assert_receive {:called, "lifecycle.cancel", %{"lease_id" => "lease-1"}}
    end

    # A unit nothing has loaded has no failed state to clear, which is not a
    # reason to refuse the restart that would load it.
    test "a reset of a unit nothing has loaded yet does not refuse the restart", context do
      opts =
        restart_opts(context,
          pids: ["100", "412"],
          cmd: fn
            "systemctl", ["--user", "reset-failed", _unit] ->
              {"Unit fermix.service not loaded.", 1}

            "systemctl", ["--user", "show" | _rest] ->
              {active_properties(), 0}

            _executable, _args ->
              {"", 0}
          end
        )

      assert {:ok, result} = Packaged.restart(opts)
      assert result["pid"] == "412"

      assert_receive {:ran, "systemctl", ["--user", "restart", @unit]}
      refute_received {:called, "lifecycle.cancel", _params}
    end

    # §4.1's recovery row: with nothing answering there is no lease to take and
    # no previous pid, and the restart still has to run.
    test "a daemon that is not answering is recovered, not refused", context do
      opts = restart_opts(context, pids: [:down, "412"])

      assert {:ok, result} = Packaged.restart(opts)
      assert result["previous_pid"] == nil
      assert result["pid"] == "412"

      refute_received {:called, "lifecycle.prepare", _params}
      assert_receive {:ran, "systemctl", ["--user", "restart", @unit]}
    end

    test "a daemon that will not open a window refuses before anything is restarted", context do
      opts =
        restart_opts(context,
          pids: ["100"],
          request: fn _socket, "lifecycle.prepare", _params -> {:error, :busy} end
        )

      assert {:error, {:lifecycle_refused, sentence}} = Packaged.restart(opts)
      assert is_binary(sentence)
      refute_received {:ran, "systemctl", ["--user", "restart", _unit]}
    end

    test "no bound home is its own refusal, not a guessed one", context do
      SafeRm.rm_rf!(context.config_root)

      assert Packaged.restart(restart_opts(context, pids: ["100"])) == {:error, :service_unbound}
    end

    # The alignment is the same typed comparison `service status` publishes, so
    # a restart that loaded the wrong engine says so rather than reporting done.
    test "a new generation of another build reports the skew it found", context do
      older = %{Map.drop(installed_identity(), ["engine_id"]) | "build_id" => "release-8"}

      opts =
        restart_opts(context,
          pids: ["100", "412"],
          engine: fn
            "412" -> older
            _other -> Map.drop(installed_identity(), ["engine_id"])
          end
        )

      assert {:ok, result} = Packaged.restart(opts)
      assert result["alignment"] == "pending_restart"
    end
  end

  defp restart_opts(context, overrides) do
    test = self()
    pids = Keyword.fetch!(overrides, :pids)
    counter = :counters.new(1, [])

    engine =
      Keyword.get(overrides, :engine, fn _pid -> Map.drop(installed_identity(), ["engine_id"]) end)

    hello = fn _socket_path ->
      index = min(:counters.get(counter, 1), length(pids) - 1)
      :counters.add(counter, 1, 1)

      case Enum.at(pids, index) do
        :down -> {:error, :not_running}
        pid -> {:ok, %{"engine" => Map.put(engine.(pid), "pid", pid)}}
      end
    end

    request =
      Keyword.get(overrides, :request, fn _socket, _method, _params ->
        {:ok, %{"lease_id" => "lease-1", "ttl_ms" => 30_000}}
      end)

    # Both seams report what they were asked to do, so a test can refute a call
    # as well as assert one.
    wrapped_request = fn socket, method, params ->
      send(test, {:called, method, params})
      request.(socket, method, params)
    end

    wrapped_cmd =
      case Keyword.fetch(overrides, :cmd) do
        {:ok, cmd} ->
          [
            cmd: fn executable, args ->
              send(test, {:ran, executable, args})
              cmd.(executable, args)
            end
          ]

        :error ->
          []
      end

    context
    |> opts(wrapped_cmd ++ Keyword.take(overrides, [:properties, :daemon_reload]))
    |> Keyword.merge(hello: hello, request: wrapped_request, poll_attempts: 4)
  end

  defp opts(context, overrides \\ []) do
    defaults = [
      binding_root: context.config_root,
      user_unit_path: context.unit_path,
      engine_manifest_path: context.manifest_path,
      default_home: context.home,
      build_info: PackagedBuildInfo,
      cmd:
        runner(
          properties: Keyword.get(overrides, :properties, active_properties()),
          linger_state: Keyword.get(overrides, :linger_state, {"yes\n", 0}),
          enable_linger: Keyword.get(overrides, :enable_linger, {"", 0}),
          reset_failed: Keyword.get(overrides, :reset_failed, {"", 0}),
          daemon_reload: Keyword.get(overrides, :daemon_reload, {"", 0})
        ),
      username: fn _opts -> "operator" end,
      find_executable: fn _name -> "/usr/bin/loginctl" end,
      hello: fn _socket_path -> {:ok, hello()} end,
      health_probe: fn _origin -> :ok end,
      sleep: fn _ms -> :ok end,
      poll_attempts: 4
    ]

    overrides
    |> Keyword.drop([:properties, :linger_state, :enable_linger, :reset_failed, :daemon_reload])
    |> Keyword.merge(defaults, fn _key, override, _default -> override end)
  end

  defp runner(fixtures) do
    test = self()

    fn executable, args ->
      send(test, {:ran, executable, args})
      answer(executable, args, fixtures)
    end
  end

  defp answer("systemctl", ["--user", "show" | _rest], fixtures),
    do: {Keyword.fetch!(fixtures, :properties), 0}

  defp answer("loginctl", ["show-user" | _rest], fixtures),
    do: Keyword.fetch!(fixtures, :linger_state)

  defp answer("systemctl", ["--user", "daemon-reload" | _rest], fixtures),
    do: Keyword.fetch!(fixtures, :daemon_reload)

  defp answer("systemctl", ["--user", "reset-failed" | _rest], fixtures),
    do: Keyword.fetch!(fixtures, :reset_failed)

  defp answer("loginctl", ["enable-linger" | _rest], fixtures),
    do: Keyword.fetch!(fixtures, :enable_linger)

  defp answer(_executable, _args, _fixtures), do: {"", 0}

  defp unreachable_runner do
    test = self()

    fn executable, args ->
      send(test, {:ran, executable, args})
      {"Failed to connect to bus: No medium found", 1}
    end
  end

  # `systemctl show` answers `Key=Value` in systemd's own property order, which
  # is not the order the properties were asked for. This is systemd 257's order,
  # recorded from a real user manager in a Debian trixie container.
  # The state a package upgrade leaves behind: the unit on disk is newer than
  # the one this account's manager has read.
  defp needs_reload_properties do
    String.replace(active_properties(), "NeedDaemonReload=no", "NeedDaemonReload=yes")
  end

  defp active_properties do
    """
    MainPID=4711
    NRestarts=0
    ExecMainPID=4711
    LoadState=loaded
    ActiveState=active
    SubState=running
    FragmentPath=#{@vendor_unit}
    DropInPaths=
    UnitFileState=enabled
    NeedDaemonReload=no
    InvocationID=4b1e9d1a
    """
  end

  defp shadowed_properties do
    String.replace(active_properties(), @vendor_unit, "/home/operator/.config/systemd/user/x")
  end

  # The fresh-package answer, exactly as systemd 257 printed it before any
  # install: loaded from the vendor unit, disabled, dead, no invocation.
  defp fresh_properties do
    """
    MainPID=0
    NRestarts=0
    ExecMainPID=0
    LoadState=loaded
    ActiveState=inactive
    SubState=dead
    FragmentPath=#{@vendor_unit}
    DropInPaths=
    UnitFileState=disabled
    NeedDaemonReload=no
    InvocationID=
    """
  end

  defp installed_identity, do: PackagedBuildInfo.public_identity()

  defp hello do
    %{
      "engine" => Map.drop(installed_identity(), ["engine_id"]),
      "setup" => %{"origin" => "http://127.0.0.1:4030", "path" => "/setup"}
    }
  end

  defp observability do
    """
    Environment="FERMIX_OPIK_ENABLED=1"
    Environment="FERMIX_OPIK_BASE_URL=http://localhost:5173/api"
    Environment=FERMIX_TRACE_CONTENT=0
    Environment=PATH=/usr/bin:/bin
    """
  end

  defp legacy_unit(home, extra \\ "") do
    escaped = home |> String.replace("%", "%%")

    """
    [Unit]
    Description=Fermix multi-agent platform daemon (user-scope)

    [Service]
    Type=simple
    Environment="FERMIX_HOME=#{escaped}"
    #{extra}
    ExecStart=/usr/local/bin/fermix run
    Restart=on-failure

    [Install]
    WantedBy=default.target
    """
  end

  defp write_unit(context, contents) do
    File.mkdir_p!(Path.dirname(context.unit_path))
    File.write!(context.unit_path, contents)
  end

  defp write_drop_in(context, name, contents) do
    dir = context.unit_path <> ".d"
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, contents)
    path
  end
end
