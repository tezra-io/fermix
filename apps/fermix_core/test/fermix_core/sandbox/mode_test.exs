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

  test "developer mode includes launch cwd and existing common project roots under home" do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-mode")
    project = Path.join(home, "projects")
    launch = Path.join(project, "app")
    File.mkdir_p!(launch)
    Application.put_env(:fermix_core, :sandbox_launch_cwd, launch)

    config =
      Config.normalize(
        mode: :standard,
        workspace_root: Path.join(home, "workspace"),
        home: home
      )

    roots = Mode.effective_roots(config)

    assert PathPolicy.canonical_path(Path.join(home, "workspace")) in roots
    assert PathPolicy.canonical_path(project) in roots
    assert PathPolicy.canonical_path(launch) in roots
  end

  test "trusted local mode exposes home but leaves protected checks to path policy" do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-mode")

    config =
      Config.normalize(
        mode: :open,
        workspace_root: Path.join(home, "workspace"),
        home: home
      )

    assert Mode.effective_roots(config) == [PathPolicy.canonical_path(home)]
  end
end
