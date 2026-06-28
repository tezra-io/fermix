defmodule FermixCore.SandboxTest do
  use ExUnit.Case, async: true

  alias FermixCore.Sandbox
  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.PathPolicy

  test "enforce fails closed for unknown request shapes" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-enforce")
    context = %{sandbox_config: Config.normalize(mode: :strict, workspace_root: root)}

    assert {:deny, :invalid_request} = Sandbox.enforce(:exec, %{operation: :unknown}, context)
    assert {:deny, :invalid_request} = Sandbox.enforce(:exec, %{}, context)

    FermixTestSupport.SafeRm.rm_rf!(root)
  end

  test "shell_plan allows an in-root command and denies an outside working dir" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-shell-plan")
    outside = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-shell-plan-outside")
    context = %{sandbox_config: Config.normalize(mode: :strict, workspace_root: root)}

    # shell_plan resolves config + protected roots once and threads them into both
    # the working-dir decision and the exec decision; the allow/deny outcome must
    # be byte-identical to the per-decision self-resolving path.
    assert {:ok, %{working_dir: working_dir, env: env}} =
             Sandbox.shell_plan("echo hi", root, context)

    assert working_dir == PathPolicy.canonical_path(root)
    assert is_list(env)

    assert {:error, {:outside_root, _path}} = Sandbox.shell_plan("echo hi", outside, context)

    FermixTestSupport.SafeRm.rm_rf!(root)
    FermixTestSupport.SafeRm.rm_rf!(outside)
  end

  test "enforce applies working-dir policy to command capabilities" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-enforce-command")
    outside = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-enforce-command-outside")
    canonical_outside = PathPolicy.canonical_path(outside)
    context = %{sandbox_config: Config.normalize(mode: :strict, workspace_root: root)}

    assert :allow =
             Sandbox.enforce(:exec, %{operation: :command_capability, working_dir: root}, context)

    assert {:deny, {:outside_root, ^canonical_outside}} =
             Sandbox.enforce(
               :exec,
               %{operation: :command_capability, working_dir: outside},
               context
             )

    FermixTestSupport.SafeRm.rm_rf!(root)
    FermixTestSupport.SafeRm.rm_rf!(outside)
  end
end
