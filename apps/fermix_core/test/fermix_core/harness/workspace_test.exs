defmodule FermixCore.Harness.WorkspaceTest do
  # async: false — each case spawns a real `git` OS process via the inline
  # (supervised: false) CommandRunner path.
  use ExUnit.Case, async: false

  alias FermixCore.Harness.Workspace

  # This test file lives inside a git worktree (the fermix umbrella). Resolving
  # any directory within it must yield git's own physical toplevel, so a nested
  # dir and the repo root collapse onto one lock root. The ExUnit cwd is the app
  # dir (`apps/fermix_core`), so the umbrella root is derived, then nested dirs
  # are built beneath it.
  test "a nested dir and the repo root resolve to the same worktree root" do
    assert {:ok, root} = Workspace.lock_root(File.cwd!(), supervised: false)

    nested = Path.join(root, "apps/fermix_core")
    deeper = Path.join(root, "apps/fermix_core/lib/fermix_core/harness")

    assert {:ok, ^root} = Workspace.lock_root(nested, supervised: false)
    assert {:ok, ^root} = Workspace.lock_root(deeper, supervised: false)

    # git prints an absolute, symlink-resolved path.
    assert String.starts_with?(root, "/")
  end

  test "a non-git directory locks on its own canonical path" do
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("harness-workspace-nongit")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    # Guard the premise: the tmp dir must not itself sit inside a git worktree.
    refute File.dir?(Path.join(dir, ".git"))

    assert {:ok, ^dir} = Workspace.lock_root(dir, supervised: false)
  end

  test "a relative cwd is expanded before resolution" do
    # ExUnit runs from the app dir, so "lib" exists relative to it and both
    # resolve to the same worktree root.
    assert {:ok, root} = Workspace.lock_root("lib", supervised: false)
    assert {:ok, ^root} = Workspace.lock_root(File.cwd!(), supervised: false)
  end

  test "a missing directory fails loud" do
    missing =
      Path.join(System.tmp_dir!(), "fermix-harness-absent-#{System.unique_integer([:positive])}")

    assert {:error, {:cwd_unreachable, :enoent}} = Workspace.lock_root(missing, supervised: false)
  end

  test "a regular file is rejected as not-a-directory" do
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("harness-workspace-file")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    file = Path.join(dir, "not-a-dir")
    File.write!(file, "x")

    assert {:error, {:not_a_directory, :regular}} = Workspace.lock_root(file, supervised: false)
  end
end
