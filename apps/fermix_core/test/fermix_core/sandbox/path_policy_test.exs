defmodule FermixCore.Sandbox.PathPolicyTest do
  use ExUnit.Case, async: false

  alias FermixCore.Sandbox.Config
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
    config = Config.normalize(mode: :open, home: home, workspace_root: home)

    assert {:error, {:protected_path, _path}} =
             PathPolicy.allowed_path?(Path.join(home, ".SSH/evil_key"), config)

    FermixTestSupport.SafeRm.rm_rf!(home)
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
