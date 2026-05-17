defmodule FermixCore.Sandbox.TelemetryTest do
  use ExUnit.Case, async: false

  alias FermixCore.Sandbox
  alias FermixCore.Sandbox.Config

  @context %{agent_name: "test_agent", conversation_key: :test}

  test "emits allow, deny, and hardline decisions" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-telemetry")

    context =
      Map.put(@context, :sandbox_config, Config.normalize(mode: :strict, workspace_root: root))

    handler = attach_telemetry()

    assert :allow = Sandbox.enforce(:exec, %{operation: :shell, working_dir: root}, context)

    assert {:error, {:outside_root, _path}} =
             Sandbox.shell_plan("echo hi", System.tmp_dir!(), context)

    assert {:error, {:hardline, _reason}} = Sandbox.shell_plan("rm -rf /", root, context)

    assert_receive {:sandbox_decision, :allow, _metadata}
    assert_receive {:sandbox_decision, :deny, _metadata}
    assert_receive {:sandbox_decision, :hardline, _metadata}

    :telemetry.detach(handler)
    FermixTestSupport.SafeRm.rm_rf!(root)
  end

  defp attach_telemetry do
    handler = "sandbox-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:fermix, :sandbox, :decision],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:sandbox_decision, metadata.decision, metadata})
      end,
      nil
    )

    handler
  end
end
