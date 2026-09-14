defmodule Fermix.CLI.ServiceTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.Service
  alias Fermix.CLI.Service.Binding

  @vendor_unit "/usr/lib/systemd/user/fermix.service"

  defmodule AppBuildInfo do
    def app_engine?, do: true
    def linux_package?, do: false
  end

  defmodule PackagedBuildInfo do
    def app_engine?, do: false
    def linux_package?, do: true
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
