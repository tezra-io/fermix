defmodule FermixCore.Sandbox.PathPolicyTest do
  use ExUnit.Case, async: false

  alias FermixCore.Acp.IdentityStore
  alias FermixCore.Browser.Bridge.Endpoint, as: BridgeEndpoint
  alias FermixCore.Plugins.Dist.Store, as: PluginStore
  alias FermixCore.Realtime.Config, as: RealtimeConfig
  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.Mode
  alias FermixCore.Sandbox.PathPolicy
  alias FermixCore.Setup.AccessToken
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.SecretWriter.File, as: SecretFile

  test "an empty FERMIX_HOME yields absolute protected paths, not cwd-relative ones" do
    previous = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", "")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end
    end)

    config = Config.normalize(mode: :standard, workspace_root: "/tmp/workspace")
    protected = PathPolicy.protected_paths(config)

    # Pre-fix, fermix_home/0 returned "" so the home-derived entries became
    # cwd-relative (config.toml -> <repo>/config.toml). Post-fix they resolve
    # under ~/.fermix.
    assert Enum.any?(protected, &String.ends_with?(&1, "/.fermix/config.toml"))
  end

  test "denies symlink escapes after resolving the target" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-root")
    outside = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-outside")
    File.ln_s!(outside, Path.join(root, "link"))

    config = Config.normalize(mode: :strict, workspace_root: root)

    assert {:error, {:outside_root, escaped}} =
             PathPolicy.resolve_write_path("link/escape.txt", config, %{cwd: root})

    assert escaped == PathPolicy.canonical_path(Path.join(outside, "escape.txt"))

    FermixTestSupport.SafeRm.rm_rf!(root)
    FermixTestSupport.SafeRm.rm_rf!(outside)
  end

  test "a protected root reached through a symlink is protected at its target" do
    os_home = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-linked-root")
    keys = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-linked-keys")
    File.ln_s!(keys, Path.join(os_home, ".ssh"))

    config = Config.normalize(mode: :open, os_home: os_home, workspace_root: os_home)
    target = PathPolicy.canonical_path(keys)

    assert target in PathPolicy.protected_paths(config)

    assert {:error, {:protected_path, _path}} =
             PathPolicy.allowed_path?(Path.join(keys, "id_ed25519"), config)

    FermixTestSupport.SafeRm.rm_rf!(os_home)
    FermixTestSupport.SafeRm.rm_rf!(keys)
  end

  test "caps symlink resolution hops" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-hop")

    for index <- 0..65 do
      source = Path.join(root, "link#{index}")
      target = if index == 65, do: "target", else: "link#{index + 1}"
      File.ln_s!(target, source)
    end

    config = Config.normalize(mode: :strict, workspace_root: root)

    assert {:error, {:too_many_symlinks, _path}} =
             PathPolicy.resolve_write_path("link0/file.txt", config, %{cwd: root})

    FermixTestSupport.SafeRm.rm_rf!(root)
  end

  test "folds a path component to its real on-disk case" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-case")
    File.mkdir_p!(Path.join(root, ".ssh"))

    # A case-variant of the real `.ssh` dir must resolve to the real entry, so
    # the case-sensitive containment checks still recognise it.
    assert PathPolicy.canonical_path(Path.join(root, ".SSH/authorized_keys")) ==
             PathPolicy.canonical_path(Path.join(root, ".ssh/authorized_keys"))

    FermixTestSupport.SafeRm.rm_rf!(root)
  end

  test "blocks a case-variant of a protected home dir" do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-home")
    File.mkdir_p!(Path.join(home, ".ssh"))
    config = Config.normalize(mode: :open, os_home: home, workspace_root: home)

    assert {:error, {:protected_path, _path}} =
             PathPolicy.allowed_path?(Path.join(home, ".SSH/evil_key"), config)

    FermixTestSupport.SafeRm.rm_rf!(home)
  end

  test "allowed_path?/3 with precomputed roots matches allowed_path?/2 decisions" do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-precomputed")
    File.mkdir_p!(Path.join(home, ".ssh"))
    File.mkdir_p!(Path.join(home, "work"))
    config = Config.normalize(mode: :open, os_home: home, workspace_root: home)

    # The protected-roots walk happens once; the precomputed list must yield the
    # exact same allow/deny decision as the self-computing /2 arity for every
    # representative path (protected root, allowed path under root, OS root, outside).
    roots = PathPolicy.protected_paths(config)

    paths = [
      Path.join(home, ".ssh/id_rsa"),
      Path.join(home, "work/file.txt"),
      "/etc/passwd",
      Path.join(System.tmp_dir!(), "path-policy-elsewhere/file.txt")
    ]

    for path <- paths do
      assert PathPolicy.allowed_path?(path, config, roots) ==
               PathPolicy.allowed_path?(path, config)
    end

    FermixTestSupport.SafeRm.rm_rf!(home)
  end

  test "resolve_working_dir/4 with precomputed roots matches resolve_working_dir/3" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-rwd")
    config = Config.normalize(mode: :strict, workspace_root: root)
    roots = PathPolicy.protected_paths(config)
    context = %{cwd: root}

    assert PathPolicy.resolve_working_dir(root, config, context, roots) ==
             PathPolicy.resolve_working_dir(root, config, context)

    assert PathPolicy.resolve_working_dir(nil, config, context, roots) ==
             PathPolicy.resolve_working_dir(nil, config, context)

    FermixTestSupport.SafeRm.rm_rf!(root)
  end

  test "allowed_path?/4 with both root sets precomputed matches allowed_path?/2 decisions" do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-eff")
    File.mkdir_p!(Path.join(home, ".ssh"))
    File.mkdir_p!(Path.join(home, "work"))
    config = Config.normalize(mode: :open, os_home: home, workspace_root: home)

    # The effective-roots walk now happens once; the precomputed pair must yield
    # the exact same allow/deny (and deny reason) as the self-computing /2 arity.
    protected = PathPolicy.protected_paths(config)
    effective = Mode.effective_roots(config)

    paths = [
      Path.join(home, ".ssh/id_rsa"),
      Path.join(home, "work/file.txt"),
      "/etc/passwd",
      Path.join(System.tmp_dir!(), "path-policy-eff-elsewhere/file.txt")
    ]

    for path <- paths do
      assert PathPolicy.allowed_path?(path, config, protected, effective) ==
               PathPolicy.allowed_path?(path, config)
    end

    FermixTestSupport.SafeRm.rm_rf!(home)
  end

  test "resolve_working_dir/5 with both root sets precomputed matches resolve_working_dir/3" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-rwd5")
    config = Config.normalize(mode: :strict, workspace_root: root)
    protected = PathPolicy.protected_paths(config)
    effective = Mode.effective_roots(config)
    context = %{cwd: root}

    assert PathPolicy.resolve_working_dir(root, config, context, protected, effective) ==
             PathPolicy.resolve_working_dir(root, config, context)

    assert PathPolicy.resolve_working_dir(nil, config, context, protected, effective) ==
             PathPolicy.resolve_working_dir(nil, config, context)

    FermixTestSupport.SafeRm.rm_rf!(root)
  end

  test "a credential dir under the OS home is denied in standard and open even inside a granted root" do
    os_home = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-cred")
    File.mkdir_p!(Path.join(os_home, ".ssh"))
    key = Path.join(os_home, ".ssh/id_rsa")

    for mode <- [:standard, :open] do
      config =
        Config.normalize(
          mode: mode,
          os_home: os_home,
          workspace_root: Path.join(os_home, "workspace"),
          allowed_roots: [os_home]
        )

      # Protected wins over the granted root: the credential dir stays denied.
      assert {:error, {:protected_path, _path}} = PathPolicy.allowed_path?(key, config)
    end

    FermixTestSupport.SafeRm.rm_rf!(os_home)
  end

  test "fermix-state files stay protected off the fermix home, independent of os_home" do
    os_home = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-osh")
    fermix_home = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-fh")
    previous = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", fermix_home)

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      FermixTestSupport.SafeRm.rm_rf!(fermix_home)
    end)

    config =
      Config.normalize(
        mode: :open,
        os_home: os_home,
        home: fermix_home,
        workspace_root: Path.join(fermix_home, "workspace")
      )

    assert {:error, {:protected_path, _path}} =
             PathPolicy.allowed_path?(Path.join(fermix_home, "auth.json"), config)

    FermixTestSupport.SafeRm.rm_rf!(os_home)
  end

  test "protects macOS private etc alias when present" do
    if File.exists?("/private/etc") do
      root = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-private")
      config = Config.normalize(mode: :strict, workspace_root: root)

      assert {:error, {:protected_path, _path}} =
               PathPolicy.allowed_path?("/private/etc/passwd", config)

      FermixTestSupport.SafeRm.rm_rf!(root)
    end
  end

  test "open mode refuses the fermix home's secret, key, persona and trust files" do
    os_home = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-floor")
    fermix_home = Path.join(os_home, ".fermix")
    File.mkdir_p!(fermix_home)
    pin_env!("FERMIX_HOME", fermix_home)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(os_home) end)

    config = open_config(os_home, fermix_home)

    protected = [
      "secrets/fermix.OPENAI_API_KEY",
      "secret_key_base",
      "setup-token",
      "setup-launch-token.json",
      "acp_identities/relay.json",
      "mobile/devices.toml",
      "mobile/gateway_key",
      "plugins/run/github.json",
      "browser/profiles/owner/fermix/Cookies",
      "bootstrap/main/SOUL.md",
      "acp.sock",
      "realtime.sock",
      "browser_bridge.sock",
      "companion.sock",
      "memory.db-wal",
      "memory.db-shm",
      "memory.db-journal",
      "auth.json.broken.1767225600",
      "auth.json.tmp.7",
      "config.toml.pre-m5"
    ]

    for relative <- protected do
      assert {:error, {:protected_path, _path}} =
               PathPolicy.allowed_path?(Path.join(fermix_home, relative), config),
             "expected #{relative} to be protected"
    end

    # What the agent legitimately works in stays reachable: the workspace, the
    # skills folder, and what the browser downloaded or produced. The sibling
    # rule needs a `.` or `-` right after a protected name, so `memory/` (a
    # prefix of `memory.db`) and a name that merely starts with `logs` stay out.
    for relative <- [
          "workspace/notes.md",
          "skills/demo/SKILL.md",
          "browser/downloads/owner/report.pdf",
          "browser/artifacts/owner/shot.png",
          "memory/main/USER.md",
          "logsheet.csv"
        ] do
      assert :ok = PathPolicy.allowed_path?(Path.join(fermix_home, relative), config)
    end
  end

  test "every secret location the engine itself writes sits inside the protected floor" do
    os_home = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-writers")
    fermix_home = Path.join(os_home, ".fermix")
    File.mkdir_p!(fermix_home)
    pin_env!("FERMIX_HOME", fermix_home)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(os_home) end)

    config = open_config(os_home, fermix_home)
    workspace = ConfigStore.workspace_paths()
    access = AccessToken.paths(home: fermix_home)

    # Derived from the writers' own path functions, so a secret file that moves
    # fails here instead of silently leaving the floor.
    written = [
      SecretFile.directory(home: fermix_home),
      access.setup_token,
      access.launch_token,
      IdentityStore.dir(),
      PluginStore.paths(workspace.plugins).run,
      workspace.bootstrap,
      workspace.mobile,
      ConfigStore.memory_paths().database_path <> "-wal",
      ConfigStore.path(),
      RealtimeConfig.socket_path(fermix_home),
      BridgeEndpoint.socket_path()
    ]

    for path <- written do
      assert {:error, {:protected_path, _path}} = PathPolicy.allowed_path?(path, config),
             "expected #{path} to be protected"
    end
  end

  test "Claude Code's credential and state files are protected, its settings stay editable" do
    os_home = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-claude")
    pin_env!("CLAUDE_CONFIG_DIR", nil)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(os_home) end)

    config = open_config(os_home, Path.join(os_home, ".fermix"))

    for relative <- [".claude/.credentials.json", ".claude.json", ".claude.json.backup"] do
      assert {:error, {:protected_path, _path}} =
               PathPolicy.allowed_path?(Path.join(os_home, relative), config),
             "expected #{relative} to be protected"
    end

    for relative <- [".claude/settings.json", ".claude/skills/demo/SKILL.md"] do
      assert :ok = PathPolicy.allowed_path?(Path.join(os_home, relative), config)
    end
  end

  test "a relocated Claude or Codex store is protected like the default one" do
    os_home = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-relocated")
    claude_dir = Path.join(os_home, "vendor/claude")
    codex_dir = Path.join(os_home, "vendor/codex")
    pin_env!("CLAUDE_CONFIG_DIR", claude_dir)
    pin_env!("CODEX_HOME", codex_dir)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(os_home) end)

    config = open_config(os_home, Path.join(os_home, ".fermix"))

    for path <- [
          Path.join(claude_dir, ".credentials.json"),
          Path.join(claude_dir, ".claude.json"),
          Path.join(codex_dir, "auth.json")
        ] do
      assert {:error, {:protected_path, _path}} = PathPolicy.allowed_path?(path, config),
             "expected #{path} to be protected"
    end

    assert :ok = PathPolicy.allowed_path?(Path.join(claude_dir, "settings.json"), config)
  end

  test "the Linux service's env file is protected" do
    os_home = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-envfile")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(os_home) end)

    config = open_config(os_home, Path.join(os_home, ".fermix"))

    assert {:error, {:protected_path, _path}} =
             PathPolicy.allowed_path?(Path.join(os_home, ".config/fermix/env"), config)
  end

  # APFS matches names with full Unicode case folding, so `.ssh` spelled with a
  # long s (U+017F) or a sharp s (U+00DF, which folds to "ss") opens the real
  # `.ssh`. The protected check must fold the same way, whatever the host
  # filesystem.
  test "blocks Unicode case-fold variants of a protected home dir" do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-fold")
    File.mkdir_p!(Path.join(home, ".ssh"))
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)

    config = Config.normalize(mode: :open, os_home: home, workspace_root: home)

    for variant <- [".\u017Fsh", ".s\u017Fh", ".\u00DFh"] do
      assert {:error, {:protected_path, _path}} =
               PathPolicy.allowed_path?(Path.join([home, variant, "id_rsa"]), config),
             "expected #{inspect(variant)} to be protected"
    end
  end

  test "blocks a fold variant of a protected dir that does not exist yet" do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-fold-new")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)

    config = Config.normalize(mode: :open, os_home: home, workspace_root: home)

    # On APFS, creating this directory would make every later `~/.aws` lookup
    # land in it.
    assert {:error, {:protected_path, _path}} =
             PathPolicy.allowed_path?(Path.join(home, ".aw\u017F/config"), config)
  end

  test "blocks a ligature variant of a protected file" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-ligature")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)

    config = Config.normalize(mode: :strict, workspace_root: root)
    protected = [PathPolicy.canonical_path(Path.join(root, "config.toml"))]

    assert {:error, {:protected_path, _path}} =
             PathPolicy.allowed_path?(Path.join(root, "con\uFB01g.toml"), config, protected)
  end

  test "blocks a case-fold variant of a blocked root" do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("path-policy-fold-blocked")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
    # Blocked roots are compared as configured, so name the tmp dir canonically.
    home = PathPolicy.canonical_path(home)

    config =
      Config.normalize(
        mode: :open,
        os_home: home,
        workspace_root: home,
        blocked_roots: [Path.join(home, "secret")]
      )

    assert {:error, {:blocked_root, _path}} =
             PathPolicy.allowed_path?(Path.join(home, "\u017Fecret/plan.md"), config)
  end

  defp open_config(os_home, fermix_home) do
    Config.normalize(
      mode: :open,
      os_home: os_home,
      home: fermix_home,
      workspace_root: Path.join(fermix_home, "workspace")
    )
  end

  # Sets (or, with nil, unsets) an env var for this test and restores whatever
  # the host had, so the suite never depends on the developer's shell.
  defp pin_env!(name, value) do
    previous = System.get_env(name)
    put_or_delete_env(name, value)
    on_exit(fn -> put_or_delete_env(name, previous) end)
  end

  defp put_or_delete_env(name, nil), do: System.delete_env(name)
  defp put_or_delete_env(name, value), do: System.put_env(name, value)
end
