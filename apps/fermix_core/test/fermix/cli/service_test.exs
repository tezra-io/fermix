defmodule Fermix.CLI.ServiceTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.Service
  alias Fermix.CLI.Service.Binding
  alias Fermix.CLI.Service.Templates

  @vendor_unit "/usr/lib/systemd/user/fermix.service"

  defmodule AppBuildInfo do
    def app_engine?, do: true
    def linux_package?, do: false
  end

  defmodule PackagedBuildInfo do
    def app_engine?, do: false
    def linux_package?, do: true
  end

  defmodule StandaloneBuildInfo do
    def app_engine?, do: false
    def linux_package?, do: false
  end

  # Stands in for systemd, so an install writes its unit and goes no further.
  defmodule InertBackend do
    def install(_spec), do: :ok
  end

  describe "app-managed mutation guard" do
    test "all legacy service mutations fail before OS dispatch" do
      opts = [build_info: AppBuildInfo, os: :unsupported]

      for action <- [:install, :uninstall, :start, :stop, :restart] do
        assert {:error, {:app_managed, :legacy_service}} = apply(Service, action, [:user, opts])
      end
    end
  end

  describe "spec/2 (linux)" do
    test "user-scope writes to ~/.config/systemd/user" do
      tmp = mkdir!()
      {:ok, spec} = Service.spec(:user, fixture_opts(:linux, tmp))

      assert spec.os == :linux
      assert spec.scope == :user
      assert spec.linux_unit == "fermix.service"
      assert spec.fermix_home == tmp
      assert String.ends_with?(spec.unit_path, ".config/systemd/user/fermix.service")
    end

    test "system-scope writes to /etc/systemd/system" do
      tmp = mkdir!()
      {:ok, spec} = Service.spec(:system, fixture_opts(:linux, tmp))

      assert spec.unit_path == "/etc/systemd/system/fermix.service"
    end
  end

  # The account a system unit runs the daemon as. `sudo` exports the invoking
  # account as SUDO_USER/SUDO_UID; tests inject them through `:env`, and
  # `system_opts/2` makes the offer `fermix service install` makes. Only the
  # paths that render a unit resolve the account, so it is read off that unit.
  describe "system-scope account (linux)" do
    test "a new system unit runs as the sudo invoker when the home it serves is theirs" do
      tmp = mkdir!()
      opts = system_opts(tmp, sudo_env("ada", invoker_uid!(tmp)))

      {:ok, unit} = Service.render_unit(:system, opts)

      assert unit_lines(unit, "User=") == ["User=ada"]
      assert unit =~ ~s(Environment="FERMIX_HOME=#{tmp}")
    end

    # A setup run under sudo has just configured the home as root, so its
    # secrets are root's; a daemon dropped to the invoker could not read them.
    test "a new system unit nobody offered to the invoker stays root" do
      tmp = mkdir!()
      opts = Keyword.delete(system_opts(tmp, sudo_env("ada", owner_uid(tmp))), :account)

      assert account_lines(:system, opts) == []
    end

    # `sudo` resets HOME to root's on most hosts, so the home the unit would
    # serve is root's: a daemon dropped to the invoker could not even open it.
    test "a home that is not the invoker's keeps the root shape" do
      tmp = mkdir!()
      opts = system_opts(tmp, sudo_env("ada", owner_uid(tmp) + 1))

      assert account_lines(:system, opts) == []
    end

    test "a home whose state is the invoker's runs as the invoker" do
      tmp = mkdir!()
      opts = system_opts(tmp, sudo_env("ada", invoker_uid!(tmp, home_state!(tmp))))

      assert account_lines(:system, opts) == ["User=ada"]
    end

    # A root daemon that served the home, or a setup run under `sudo -E`, leaves
    # root-owned files in a directory that is still the invoker's: the database's
    # WAL, a rotated log, a secret. A daemon dropped to the invoker could neither
    # write nor read them. Each entry is followed to a file root owns, as the
    # daemon would open it.
    test "a home holding state that is not the invoker's keeps the root shape" do
      for entry <- ["memory.db-wal", "logs/fermix.log.1", "secrets/openai_api_key"] do
        tmp = mkdir!()
        uid = invoker_uid!(tmp, home_state!(tmp))
        File.ln_s!("/etc/hosts", Path.join(tmp, entry))

        assert account_lines(:system, system_opts(tmp, sudo_env("ada", uid))) == [], entry
      end
    end

    test "a home that does not exist yet keeps the root shape" do
      tmp = mkdir!()

      opts =
        tmp
        |> system_opts(sudo_env("ada", owner_uid(tmp)))
        |> Keyword.put(:fermix_home, Path.join(tmp, "not-yet"))

      assert account_lines(:system, opts) == []
    end

    test "without sudo, or under sudo from root, the system unit names no account" do
      tmp = mkdir!()

      for env <- [%{}, sudo_env("root", 0), %{"SUDO_USER" => "ada"}] do
        assert account_lines(:system, system_opts(tmp, env)) == []
      end
    end

    # `sudo` exports whatever the account database calls the account. A name a
    # `User=` line cannot carry literally keeps the root unit every system
    # install wrote before accounts existed, instead of crashing the install.
    test "an invoker name a unit file cannot carry keeps the root shape" do
      tmp = mkdir!()
      uid = invoker_uid!(tmp)

      for name <- ["a da", "ada%i"] do
        assert account_lines(:system, system_opts(tmp, sudo_env(name, uid))) == []
      end
    end

    test "a user unit never names an account" do
      tmp = mkdir!()
      opts = Keyword.put(fixture_opts(:linux, tmp), :env, sudo_env("ada", owner_uid(tmp)))

      assert account_lines(:user, opts) == []
    end

    # A root daemon has been writing root-owned files into its home; moving it
    # to another account on a rewrite would lock it out of them.
    test "an installed system unit keeps the account it names" do
      tmp = mkdir!()
      opts = system_opts(tmp, sudo_env("ada", owner_uid(tmp)))
      unit_path = Keyword.fetch!(opts, :unit_path)

      File.write!(unit_path, installed_unit([home_line(tmp)]))
      assert account_lines(:system, opts) == []

      File.write!(unit_path, installed_unit(["User=bob", home_line(tmp)]))
      assert account_lines(:system, opts) == ["User=bob"]
    end

    # The account and the home it serves are one pair. `sudo` resets HOME on
    # most hosts, so a later `sudo fermix setup --system` resolves root's home;
    # rewriting ada's unit for it would start a daemon that cannot open its own
    # home and restarts forever.
    test "an installed account is never rewritten for a home its unit does not name" do
      tmp = mkdir!()
      installed_home = Path.join(tmp, "ada")
      opts = system_opts(tmp, %{})
      unit_path = Keyword.fetch!(opts, :unit_path)
      installed = installed_unit(["User=ada", home_line(installed_home)])
      File.write!(unit_path, installed)

      mismatch = {:account_home_mismatch, "ada", installed_home, tmp}

      assert {:error, ^mismatch} = Service.render_unit(:system, opts)
      assert Service.drifted?(:system, opts)
      assert {:error, ^mismatch} = Service.install(:system, opts)
      assert File.read!(unit_path) == installed
    end

    test "an installed account whose unit names no home is refused, not guessed" do
      tmp = mkdir!()
      opts = system_opts(tmp, %{})
      File.write!(Keyword.fetch!(opts, :unit_path), installed_unit(["User=ada"]))

      assert {:error, {:account_home_mismatch, "ada", nil, ^tmp}} =
               Service.render_unit(:system, opts)
    end

    # A hand-edited `User=` that no unit file can carry is refused by name
    # rather than raised out of the render in the middle of setup.
    test "an installed account a unit file cannot carry is an error, not a crash" do
      tmp = mkdir!()
      opts = system_opts(tmp, %{})
      unit_path = Keyword.fetch!(opts, :unit_path)
      File.write!(unit_path, installed_unit(["User=a b", home_line(tmp)]))

      assert {:error, {:invalid_account, ^unit_path, "a b"}} =
               Service.render_unit(:system, opts)

      assert Service.drifted?(:system, opts)
    end

    test "reconciling a drifted root unit rewrites it as root" do
      tmp = mkdir!()
      opts = system_opts(tmp, sudo_env("ada", owner_uid(tmp)))
      unit_path = Keyword.fetch!(opts, :unit_path)
      File.write!(unit_path, "[Service]\nExecStart=/old/fermix run\n")

      assert Service.drifted?(:system, opts)

      {:ok, rewritten} = Service.render_unit(:system, opts)
      File.write!(unit_path, rewritten)

      refute rewritten =~ "User="
      assert rewritten =~ "IPAddressDeny="
      refute Service.drifted?(:system, opts)
    end

    test "an installed unit that cannot be read is an error, not a guess" do
      tmp = mkdir!()
      opts = system_opts(tmp, %{})
      unit_path = Keyword.fetch!(opts, :unit_path)
      File.mkdir_p!(unit_path)

      assert {:error, {:unit_unreadable, ^unit_path, :eisdir}} =
               Service.render_unit(:system, opts)
    end

    # systemd's own mode for a unit, whatever the installer's umask: the account
    # a unit names, and that account's CLI, read it back.
    test "a system unit is written 0644, whatever mode the file had" do
      tmp = mkdir!()
      opts = system_opts(tmp, %{})
      unit_path = Keyword.fetch!(opts, :unit_path)
      File.write!(unit_path, installed_unit([home_line(tmp)]))
      File.chmod!(unit_path, 0o600)

      assert :ok = Service.install(:system, opts)
      assert Bitwise.band(File.stat!(unit_path).mode, 0o777) == 0o644
    end

    # The daemon creates its log directory at boot, as the account it runs as.
    # Made by the installer it would be root's, and the daemon could not log.
    test "a unit that runs as an account leaves its log directory to the daemon" do
      tmp = mkdir!()
      opts = system_opts(tmp, sudo_env("ada", invoker_uid!(tmp)))

      assert :ok = Service.install(:system, opts)
      assert unit_lines(File.read!(Keyword.fetch!(opts, :unit_path)), "User=") == ["User=ada"]
      refute File.exists?(Path.join(tmp, "logs"))
    end
  end

  describe "spec/2 (darwin)" do
    test "user-scope writes to ~/Library/LaunchAgents" do
      tmp = mkdir!()
      {:ok, spec} = Service.spec(:user, fixture_opts(:darwin, tmp))

      assert spec.os == :darwin
      assert spec.label == "io.tezra.fermix"
      assert String.ends_with?(spec.unit_path, "Library/LaunchAgents/io.tezra.fermix.plist")
    end

    test "system-scope writes to /Library/LaunchDaemons" do
      tmp = mkdir!()
      {:ok, spec} = Service.spec(:system, fixture_opts(:darwin, tmp))

      assert spec.unit_path == "/Library/LaunchDaemons/io.tezra.fermix.plist"
    end
  end

  describe "render_unit/2" do
    test "darwin renders a launchd plist" do
      tmp = mkdir!()
      {:ok, body} = Service.render_unit(:user, fixture_opts(:darwin, tmp))

      assert body =~ "<key>Label</key><string>io.tezra.fermix</string>"
      assert body =~ "<key>FERMIX_HOME</key><string>#{tmp}</string>"
    end

    test "linux renders a systemd unit" do
      tmp = mkdir!()
      {:ok, body} = Service.render_unit(:user, fixture_opts(:linux, tmp))

      assert body =~ "Type=simple"
      assert body =~ ~s(Environment="FERMIX_HOME=#{tmp}")
    end
  end

  describe "spec/2 service_env" do
    test "includes allowlisted observability vars from explicit env, FERMIX_HOME baseline" do
      tmp = mkdir!()

      opts =
        Keyword.put(fixture_opts(:linux, tmp), :env, %{
          "FERMIX_OPIK_ENABLED" => "1",
          "FERMIX_OPIK_BASE_URL" => "http://localhost:5173/api",
          "FERMIX_OPIK_PROJECT" => "fermix",
          "FERMIX_TRACE_CONTENT" => "1"
        })

      {:ok, spec} = Service.spec(:user, opts)

      assert spec.service_env["FERMIX_HOME"] == tmp
      assert spec.service_env["FERMIX_OPIK_ENABLED"] == "1"
      assert spec.service_env["FERMIX_OPIK_BASE_URL"] == "http://localhost:5173/api"
      assert spec.service_env["FERMIX_OPIK_PROJECT"] == "fermix"
      assert spec.service_env["FERMIX_TRACE_CONTENT"] == "1"
    end

    test "never persists FERMIX_OPIK_API_KEY even when present in env" do
      tmp = mkdir!()

      opts =
        Keyword.put(fixture_opts(:linux, tmp), :env, %{
          "FERMIX_OPIK_ENABLED" => "1",
          "FERMIX_OPIK_API_KEY" => "sk-secret"
        })

      {:ok, spec} = Service.spec(:user, opts)

      refute Map.has_key?(spec.service_env, "FERMIX_OPIK_API_KEY")
      assert spec.service_env["FERMIX_OPIK_ENABLED"] == "1"
    end

    test "rejects non-allowlisted env keys (incl. a stray PATH), keeping FERMIX_HOME + computed PATH" do
      tmp = mkdir!()
      opts = Keyword.put(fixture_opts(:linux, tmp), :env, %{"PATH" => "/x", "FOO" => "bar"})
      {:ok, spec} = Service.spec(:user, opts)

      assert Enum.sort(Map.keys(spec.service_env)) == ["FERMIX_HOME", "PATH"]
      # The install-time shell PATH is never copied into the unit; PATH is computed.
      refute spec.service_env["PATH"] == "/x"
      refute Map.has_key?(spec.service_env, "FOO")
    end

    test "drops blank observability values" do
      tmp = mkdir!()
      opts = Keyword.put(fixture_opts(:linux, tmp), :env, %{"FERMIX_OPIK_ENABLED" => ""})
      {:ok, spec} = Service.spec(:user, opts)

      refute Map.has_key?(spec.service_env, "FERMIX_OPIK_ENABLED")
    end

    test "render_unit carries allowlisted env and omits the api key (darwin)" do
      tmp = mkdir!()

      opts =
        Keyword.put(fixture_opts(:darwin, tmp), :env, %{
          "FERMIX_OPIK_ENABLED" => "1",
          "FERMIX_OPIK_API_KEY" => "sk-secret"
        })

      {:ok, body} = Service.render_unit(:user, opts)

      assert body =~ "<key>FERMIX_OPIK_ENABLED</key><string>1</string>"
      refute body =~ "FERMIX_OPIK_API_KEY"
      refute body =~ "sk-secret"
    end
  end

  describe "spec/2 service_env PATH" do
    test "darwin pins the fermix install dir, the Homebrew prefix, and system dirs" do
      tmp = mkdir!()
      # A Homebrew install: cosign lives next to fermix in /opt/homebrew/bin.
      opts = Keyword.put(fixture_opts(:darwin, tmp), :fermix_path, "/opt/homebrew/bin/fermix")
      {:ok, spec} = Service.spec(:user, opts)

      dirs = String.split(spec.service_env["PATH"], ":")

      assert "/opt/homebrew/bin" in dirs
      assert "/usr/bin" in dirs
      assert "/bin" in dirs
      # No duplicate when the install dir already is a standard bin dir.
      assert dirs == Enum.uniq(dirs)
    end

    test "leads with a non-standard fermix install dir" do
      tmp = mkdir!()
      # fixture fermix_path is <tmp>/fermix, so its directory leads the PATH.
      {:ok, spec} = Service.spec(:user, fixture_opts(:darwin, tmp))

      assert String.starts_with?(spec.service_env["PATH"], "#{tmp}:")
      assert spec.service_env["PATH"] =~ "/opt/homebrew/bin"
    end

    # Both official vendor-CLI installers put their binaries in ~/.local/bin, so a
    # service PATH without it makes the daemon report "no coding agent CLI is
    # detected" on a machine where the operator's own shell resolves both. It is
    # LAST because PATH is first-match-wins: a tail entry can only make an
    # unresolvable name resolvable, never shadow the cosign/node/python this list
    # was widened to reach in the first place.
    test "both platforms end with the user-scope bin dir, and nothing shadows the standard dirs" do
      tmp = mkdir!()
      user_bin = Path.join(System.user_home!(), ".local/bin")
      # Linux appends one more tail entry, the Linux package's own helper
      # directory, which is where a distribution install keeps `cosign`.
      tails = %{darwin: [user_bin], linux: [user_bin, "/usr/lib/fermix"]}

      for {os, tail} <- tails do
        {:ok, spec} = Service.spec(:user, fixture_opts(os, tmp))
        dirs = String.split(spec.service_env["PATH"], ":")

        assert user_bin in dirs, "#{os} PATH is missing #{user_bin}"

        assert Enum.take(dirs, -length(tail)) == tail,
               "#{os} must not let the user dir shadow system dirs"

        assert dirs == Enum.uniq(dirs)
      end
    end

    test "linux omits the Homebrew prefix" do
      tmp = mkdir!()
      {:ok, spec} = Service.spec(:user, fixture_opts(:linux, tmp))

      dirs = String.split(spec.service_env["PATH"], ":")

      refute "/opt/homebrew/bin" in dirs
      assert "/usr/local/bin" in dirs
      assert "/usr/bin" in dirs
    end

    test "render_unit carries the computed PATH (darwin plist and linux unit)" do
      tmp = mkdir!()

      {:ok, plist} = Service.render_unit(:user, fixture_opts(:darwin, tmp))
      assert plist =~ "<key>PATH</key><string>#{tmp}:/opt/homebrew/bin"

      {:ok, unit} = Service.render_unit(:user, fixture_opts(:linux, tmp))
      assert unit =~ ~s(Environment="PATH=#{tmp}:/usr/local/bin)
    end
  end

  describe "installed?/2" do
    test "false when unit-path file is absent" do
      tmp = mkdir!()
      opts = fixture_opts(:linux, tmp) ++ [unit_path: Path.join(tmp, "missing.service")]

      refute Service.installed?(:user, opts)
    end

    test "true once a file exists at unit-path" do
      tmp = mkdir!()
      unit_path = Path.join(tmp, "fermix.service")
      File.write!(unit_path, "stub\n")
      opts = fixture_opts(:linux, tmp) ++ [unit_path: unit_path]

      assert Service.installed?(:user, opts)
    end

    # Installed means the file exists, not that this caller can read it. A daemon
    # running as the unit's account, and that account's CLI, ask this of a
    # root-owned system unit; answering false refuses their restart and reports
    # no service at all.
    test "true for an installed system unit the caller cannot read" do
      tmp = mkdir!()
      opts = system_opts(tmp, %{})
      unit_path = Keyword.fetch!(opts, :unit_path)
      File.write!(unit_path, installed_unit(["User=ada", home_line(tmp)]))
      File.chmod!(unit_path, 0o000)
      on_exit(fn -> File.chmod(unit_path, 0o644) end)

      assert Service.installed?(:system, opts)
      assert {:ok, %{unit_path: ^unit_path}} = Service.spec(:system, opts)
    end
  end

  describe "drifted?/2" do
    test "false when the on-disk unit matches the rendered unit" do
      tmp = mkdir!()
      opts = fixture_opts(:linux, tmp) ++ [unit_path: Path.join(tmp, "fermix.service")]
      {:ok, body} = Service.render_unit(:user, opts)
      File.write!(Keyword.fetch!(opts, :unit_path), body)

      refute Service.drifted?(:user, opts)
    end

    test "true when the on-disk unit differs (e.g. a stale unit with no PATH)" do
      tmp = mkdir!()
      unit_path = Path.join(tmp, "fermix.service")
      File.write!(unit_path, "[Service]\nEnvironment=FERMIX_HOME=#{tmp}\n")
      opts = fixture_opts(:linux, tmp) ++ [unit_path: unit_path]

      assert Service.drifted?(:user, opts)
    end

    test "true when no unit file exists at the path" do
      tmp = mkdir!()
      opts = fixture_opts(:linux, tmp) ++ [unit_path: Path.join(tmp, "missing.service")]

      assert Service.drifted?(:user, opts)
    end
  end

  describe "spec/2 fermix_path (Homebrew)" do
    test "rewrites a Homebrew Cellar path to the stable bin symlink" do
      tmp = mkdir!()
      cellar = Path.join([tmp, "Cellar", "fermix", "0.1.0", "bin", "fermix"])
      symlink = Path.join([tmp, "bin", "fermix"])
      File.mkdir_p!(Path.dirname(cellar))
      File.write!(cellar, "stub")
      File.mkdir_p!(Path.dirname(symlink))
      File.write!(symlink, "stub")

      opts = Keyword.put(fixture_opts(:darwin, tmp), :fermix_path, cellar)
      {:ok, spec} = Service.spec(:user, opts)

      assert spec.fermix_path == symlink
    end

    test "keeps the Cellar path when the stable bin symlink is missing" do
      tmp = mkdir!()
      cellar = Path.join([tmp, "Cellar", "fermix", "0.1.0", "bin", "fermix"])
      File.mkdir_p!(Path.dirname(cellar))
      File.write!(cellar, "stub")

      opts = Keyword.put(fixture_opts(:darwin, tmp), :fermix_path, cellar)
      {:ok, spec} = Service.spec(:user, opts)

      assert spec.fermix_path == cellar
    end

    test "leaves a non-Cellar path unchanged" do
      tmp = mkdir!()
      {:ok, spec} = Service.spec(:user, fixture_opts(:darwin, tmp))

      assert spec.fermix_path == Path.join(tmp, "fermix")
    end
  end

  # M38 §4.4: the three predicates every self-restart and every setup launch
  # gates on. A packaged engine writes no unit, so the standalone answers — "is
  # there a file at the path I would write" — are structurally wrong for it.
  describe "packaged predicates" do
    test "installed? needs both a bound home and the package's own unit" do
      tmp = mkdir!()
      config_root = Path.join(tmp, "config")
      :ok = Binding.write(tmp, root: config_root)

      bound = packaged_opts(config_root, @vendor_unit)

      assert Service.installed?(:user, bound)

      shadowed = packaged_opts(config_root, Path.join(tmp, "fermix.service"))

      refute Service.installed?(:user, shadowed)
      refute Service.installed?(:user, packaged_opts(Path.join(tmp, "empty"), @vendor_unit))
    end

    # The package owns one user unit, so reporting the same service under a
    # system scope would have `Diagnostics` publish a scope that does not exist.
    test "installed? is false for a system scope a package never installs" do
      tmp = mkdir!()
      config_root = Path.join(tmp, "config")
      :ok = Binding.write(tmp, root: config_root)

      refute Service.installed?(:system, packaged_opts(config_root, @vendor_unit))
    end

    # Nothing here renders a packaged unit, so there is nothing to compare: a
    # true answer would send `fermix setup` into a rewrite path that must never
    # write over the package's file.
    test "drifted? is false for a packaged engine" do
      tmp = mkdir!()

      refute Service.drifted?(:user, packaged_opts(Path.join(tmp, "config"), @vendor_unit))
    end

    # The vendor unit is installed on every packaged host, so its presence says
    # nothing about THIS process. `INVOCATION_ID` is what systemd sets in the
    # service it started, and a binary run from a shell carries none.
    test "supervised? reads the service invocation, not the unit file" do
      tmp = mkdir!()
      config_root = Path.join(tmp, "config")
      :ok = Binding.write(tmp, root: config_root)
      base = packaged_opts(config_root, @vendor_unit) ++ [standalone?: fn -> true end]

      assert Service.supervised?(base ++ [invocation_id: "4b1e9d1a"])
      refute Service.supervised?(base ++ [invocation_id: nil])
      refute Service.supervised?(base ++ [invocation_id: ""])

      refute Service.supervised?(
               packaged_opts(config_root, @vendor_unit) ++
                 [standalone?: fn -> false end, invocation_id: "4b1e9d1a"]
             )
    end

    test "supervised? still reads the unit file for a standalone release" do
      tmp = mkdir!()
      unit_path = Path.join(tmp, "fermix.service")
      opts = fixture_opts(:linux, tmp) ++ [unit_path: unit_path, standalone?: fn -> true end]

      refute Service.supervised?(opts ++ [invocation_id: "4b1e9d1a"])

      File.write!(unit_path, "stub\n")

      assert Service.supervised?(opts)
    end
  end

  defp packaged_opts(config_root, fragment_path) do
    [
      build_info: PackagedBuildInfo,
      binding_root: config_root,
      cmd: fn "systemctl", ["--user", "show" | _rest] -> {show_output(fragment_path), 0} end
    ]
  end

  # `systemctl show` prints one `Key=Value` per requested property, in systemd's
  # own order rather than the requested one. This is systemd 257's order.
  defp show_output(fragment_path) do
    """
    MainPID=4711
    NRestarts=0
    ExecMainPID=4711
    LoadState=loaded
    ActiveState=active
    SubState=running
    FragmentPath=#{fragment_path}
    DropInPaths=
    UnitFileState=enabled
    NeedDaemonReload=no
    InvocationID=4b1e9d1a
    """
  end

  # Explicit empty `:env` keeps tests hermetic — the spec snapshots the process
  # env only when `:env` is absent, and a dev shell already exports
  # FERMIX_OPIK_ENABLED. Tests that exercise env propagation pass `:env` directly.
  defp fixture_opts(os, tmp) do
    [
      os: os,
      fermix_path: Path.join(tmp, "fermix"),
      fermix_home: tmp,
      log_path: Path.join(tmp, "logs/fermix.log"),
      env: %{}
    ]
  end

  # A system unit in the fixture directory, installed through `InertBackend` so
  # no case reaches the host's service manager.
  defp system_opts(tmp, env) do
    fixture_opts(:linux, tmp)
    |> Keyword.put(:unit_path, Path.join(tmp, "fermix.service"))
    |> Keyword.put(:env, env)
    |> Keyword.put(:account, :sudo_invoker)
    |> Keyword.put(:build_info, StandaloneBuildInfo)
    |> Keyword.put(:backend, InertBackend)
  end

  defp sudo_env(user, uid), do: %{"SUDO_USER" => user, "SUDO_UID" => Integer.to_string(uid)}

  defp owner_uid(path), do: File.stat!(path).uid

  # The uid of an invoker who owns `home` and the fixture `paths` made in it.
  # `sudo` from root names no account, so on a root runner, whose fixtures are
  # root's, they go to `nobody` first. Only regular files and directories: a
  # chown follows a symlink.
  defp invoker_uid!(home, paths \\ []) do
    if owner_uid(home) == 0, do: Enum.each([home | paths], &File.chown!(&1, 65_534))
    owner_uid(home)
  end

  # The state a daemon keeps in its home, made by the runner; returns its paths.
  defp home_state!(home) do
    dirs = ["logs", "secrets"]
    files = ["memory.db", "config.toml", "logs/fermix.log", "secrets/telegram_bot_token"]
    Enum.each(dirs, &File.mkdir_p!(Path.join(home, &1)))
    Enum.each(files, &File.write!(Path.join(home, &1), ""))
    Enum.map(dirs ++ files, &Path.join(home, &1))
  end

  defp account_lines(scope, opts) do
    {:ok, unit} = Service.render_unit(scope, opts)
    unit_lines(unit, "User=")
  end

  defp unit_lines(unit, prefix) do
    unit |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, prefix))
  end

  # A system unit as an earlier install left it, stale enough to be rewritten.
  defp installed_unit(lines) do
    Enum.join(["[Service]" | lines] ++ ["ExecStart=/old/fermix run", ""], "\n")
  end

  defp home_line(home), do: Templates.systemd_environment("FERMIX_HOME", home)

  defp mkdir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "fermix-service-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit_cleanup(path)
    path
  end

  defp on_exit_cleanup(path) do
    ExUnit.Callbacks.on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(path) end)
  end
end
