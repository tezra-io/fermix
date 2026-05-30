defmodule FermixCore.Sandbox.CommandToolTest do
  use ExUnit.Case, async: false

  alias FermixCore.Sandbox.CommandTool
  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.PathPolicy

  test "denies blocked default working dir before spawning command and emits telemetry" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-command-tool")
    canonical_root = PathPolicy.canonical_path(root)

    config =
      Config.normalize(
        mode: :strict,
        workspace_root: root,
        blocked_roots: [canonical_root]
      )

    handler = attach_telemetry()

    assert {:ok, %{success: false, error: error}} =
             CommandTool.execute(%{"prompt" => "ignored"}, %{sandbox_config: config}, spec())

    assert error =~ "Sandbox denied blocked root"
    assert error =~ canonical_root

    assert_receive {:sandbox_decision, :deny, metadata}
    assert metadata.operation == :command_capability
    assert metadata.policy_class == :exec

    :telemetry.detach(handler)
    FermixTestSupport.SafeRm.rm_rf!(root)
  end

  defp spec do
    %{
      command: "false",
      args: [],
      pass_env: [],
      timeout_ms: 1_000,
      description: "test command"
    }
  end

  defp attach_telemetry do
    handler = "sandbox-command-tool-#{System.unique_integer([:positive])}"
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
