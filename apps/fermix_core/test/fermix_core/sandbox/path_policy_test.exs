defmodule FermixCore.Sandbox.PathPolicyTest do
  use ExUnit.Case, async: false

  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.Mode
  alias FermixCore.Sandbox.PathPolicy

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
end
