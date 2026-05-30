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
