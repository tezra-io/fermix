defmodule FermixCore.Sandbox.ModeTest do
  use ExUnit.Case, async: false

  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.Mode
  alias FermixCore.Sandbox.PathPolicy

  setup do
    launch_cwd = Application.get_env(:fermix_core, :sandbox_launch_cwd)

    on_exit(fn ->
      case launch_cwd do
        nil -> Application.delete_env(:fermix_core, :sandbox_launch_cwd)
        value -> Application.put_env(:fermix_core, :sandbox_launch_cwd, value)
      end
    end)

    :ok
  end

  test "workspace mode exposes only workspace and explicit roots" do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-mode")
    granted = Path.join(home, "granted")
    File.mkdir_p!(granted)

    config =
      Config.normalize(
        mode: :strict,
        workspace_root: Path.join(home, "workspace"),
        allowed_roots: [granted]
      )

    assert Mode.effective_roots(config) == [
             PathPolicy.canonical_path(Path.join(home, "workspace")),
             PathPolicy.canonical_path(granted)
           ]
  end

  test "standard mode admits workspace and the launch cwd under the OS home, not project-name dirs" do
    os_home = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-mode")
    # A ~/projects dir must NOT be auto-admitted: the hardcoded name list is dropped.
    File.mkdir_p!(Path.join(os_home, "projects"))
    launch = Path.join(os_home, "app")
    File.mkdir_p!(launch)
    Application.put_env(:fermix_core, :sandbox_launch_cwd, launch)

    config =
      Config.normalize(
        mode: :standard,
        workspace_root: Path.join(os_home, "workspace"),
        os_home: os_home
      )

    roots = Mode.effective_roots(config)

    assert PathPolicy.canonical_path(Path.join(os_home, "workspace")) in roots
    assert PathPolicy.canonical_path(launch) in roots
    refute PathPolicy.canonical_path(Path.join(os_home, "projects")) in roots
  end

  test "standard mode admits an existing request cwd under the OS home via effective_roots/2" do
    os_home = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-mode")
    request = Path.join(os_home, "repos/thing")
    File.mkdir_p!(request)

    # Keep the launch cwd outside the OS home so only the request cwd can admit it.
    elsewhere = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-mode-launch")
    Application.put_env(:fermix_core, :sandbox_launch_cwd, elsewhere)

    config =
      Config.normalize(
        mode: :standard,
        workspace_root: Path.join(os_home, "workspace"),
        os_home: os_home
      )

    refute PathPolicy.canonical_path(request) in Mode.effective_roots(config)
    assert PathPolicy.canonical_path(request) in Mode.effective_roots(config, request)
  end

  test "effective_roots/2 rejects a request cwd that is a symlink escaping the OS home" do
    os_home = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-mode")
    outside = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-mode-outside")
    File.write!(Path.join(outside, "secret.txt"), "x")
    link = Path.join(os_home, "proj")
    File.ln_s!(outside, link)

    # Keep the launch cwd outside so only the (symlinked) request cwd could admit.
    elsewhere = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-mode-launch")
    Application.put_env(:fermix_core, :sandbox_launch_cwd, elsewhere)

    config =
      Config.normalize(
        mode: :standard,
        workspace_root: Path.join(os_home, "workspace"),
        os_home: os_home
      )

    roots = Mode.effective_roots(config, link)

    refute PathPolicy.canonical_path(outside) in roots

    assert {:error, {:outside_root, _}} =
             PathPolicy.allowed_path?(
               Path.join(outside, "secret.txt"),
               config,
               PathPolicy.protected_paths(config),
               roots
             )
  end

  test "effective_roots/2 does not admit a request cwd equal to the OS home" do
    os_home = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-mode")

    elsewhere = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-mode-launch")
    Application.put_env(:fermix_core, :sandbox_launch_cwd, elsewhere)

    config =
      Config.normalize(
        mode: :standard,
        workspace_root: Path.join(os_home, "workspace"),
        os_home: os_home
      )

    refute PathPolicy.canonical_path(os_home) in Mode.effective_roots(config, os_home)
  end

  test "standard mode does not admit a launch cwd equal to the OS home" do
    os_home = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-mode")
    Application.put_env(:fermix_core, :sandbox_launch_cwd, os_home)

    config =
      Config.normalize(
        mode: :standard,
        workspace_root: Path.join(os_home, "workspace"),
        os_home: os_home
      )

    refute PathPolicy.canonical_path(os_home) in Mode.effective_roots(config)
  end

  test "effective_roots/2 refuses a non-dir, an outside-os_home path, strict mode, and a blocked root" do
    os_home = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-mode")
    under = Path.join(os_home, "proj")
    File.mkdir_p!(under)
    nondir = Path.join(os_home, "note.txt")
    File.write!(nondir, "x")
    outside = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-mode-outside")

    standard =
      Config.normalize(
        mode: :standard,
        workspace_root: Path.join(os_home, "workspace"),
        os_home: os_home
      )

    refute PathPolicy.canonical_path(nondir) in Mode.effective_roots(standard, nondir)
    refute PathPolicy.canonical_path(outside) in Mode.effective_roots(standard, outside)

    strict =
      Config.normalize(
        mode: :strict,
        workspace_root: Path.join(os_home, "workspace"),
        os_home: os_home
      )

    refute PathPolicy.canonical_path(under) in Mode.effective_roots(strict, under)

    blocked =
      Config.normalize(
        mode: :standard,
        workspace_root: Path.join(os_home, "workspace"),
        os_home: os_home,
        blocked_roots: [under]
      )

    refute PathPolicy.canonical_path(under) in Mode.effective_roots(blocked, under)
  end

  test "open mode exposes the OS home but leaves protected checks to path policy" do
    os_home = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-mode")

    config =
      Config.normalize(
        mode: :open,
        workspace_root: Path.join(os_home, "workspace"),
        os_home: os_home
      )

    assert Mode.effective_roots(config) == [PathPolicy.canonical_path(os_home)]
  end
end
