defmodule FermixCore.SandboxTest do
  use ExUnit.Case, async: true

  alias FermixCore.Sandbox
  alias FermixCore.Sandbox.Config

  test "enforce fails closed for unknown request shapes" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-enforce")
    context = %{sandbox_config: Config.normalize(mode: :strict, workspace_root: root)}

    assert {:deny, :invalid_request} = Sandbox.enforce(:exec, %{operation: :unknown}, context)
    assert {:deny, :invalid_request} = Sandbox.enforce(:exec, %{}, context)

    FermixTestSupport.SafeRm.rm_rf!(root)
  end
end
