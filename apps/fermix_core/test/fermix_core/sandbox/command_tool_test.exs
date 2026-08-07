defmodule FermixCore.Sandbox.CommandToolTest do
  use ExUnit.Case, async: false

  alias FermixCore.Sandbox.CommandTool
  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.Env
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

  # MILESTONE_29_ACP_AGENT_SURFACE §8.3: the ACP session's spawn env is applied
  # at exactly one point — here — so a `buzz` invocation the model makes inside
  # that session resolves and authenticates like every other Buzz agent's.
  # The 2026-07-26 env-sanitizer lesson demands both halves: fidelity (the child
  # can actually use the env) and isolation (nothing leaks the other way).
  describe "session_env overlay" do
    setup do
      root = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-command-tool-overlay")
      bin = Path.join(root, "bin")
      File.mkdir_p!(bin)
      # A stand-in for the `buzz` CLI: resolvable only through the overlay PATH,
      # and it dumps its own environment so the test reads what the child saw.
      File.write!(Path.join(bin, "buzz"), "#!/bin/sh\nexec /usr/bin/env\n")
      File.chmod!(Path.join(bin, "buzz"), 0o755)

      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)

      # `allowed_roots` is explicit rather than relying on open mode's os_home:
      # the default working dir is the current directory when it sits inside the
      # roots, so without this the test would pass only where the repo happens to
      # live under $HOME and deny the tmp workspace anywhere else.
      %{
        root: root,
        bin: bin,
        config: Config.normalize(mode: :open, workspace_root: root, allowed_roots: [root])
      }
    end

    test "a session_env command sees the overlay PATH and its credentials", ctx do
      context = %{
        sandbox_config: ctx.config,
        session_env: %{"PATH" => ctx.bin, "BUZZ_PRIVATE_KEY" => "nsec1fakebuzzkeyvalue"}
      }

      assert {:ok, %{success: true, output: output}} =
               CommandTool.execute(%{"prompt" => "ignored"}, context, buzz_spec())

      assert env_value(output, "BUZZ_PRIVATE_KEY") == "nsec1fakebuzzkeyvalue"
      assert env_value(output, "PATH") == ctx.bin
    end

    test "a context without session_env produces exactly the sandbox env", ctx do
      assert {:ok, %{success: true, output: output}} =
               CommandTool.execute(
                 %{"prompt" => "ignored"},
                 %{sandbox_config: ctx.config},
                 dump_spec(ctx.bin)
               )

      assert {:ok, expected} = Env.build_command(ctx.config, [])
      assert Enum.sort(env_pairs(output)) == Enum.sort(expected)
    end

    test "one call's overlay never leaks into the next call", ctx do
      overlay = %{
        sandbox_config: ctx.config,
        session_env: %{"PATH" => ctx.bin, "BUZZ_PRIVATE_KEY" => "nsec1fakebuzzkeyvalue"}
      }

      assert {:ok, %{success: true}} =
               CommandTool.execute(%{"prompt" => "ignored"}, overlay, buzz_spec())

      assert {:ok, %{success: true, output: output}} =
               CommandTool.execute(
                 %{"prompt" => "ignored"},
                 %{sandbox_config: ctx.config},
                 dump_spec(ctx.bin)
               )

      assert env_value(output, "BUZZ_PRIVATE_KEY") == nil
      refute env_value(output, "PATH") == ctx.bin
    end
  end

  # Resolved by bare name, so the overlay PATH is what makes it runnable.
  defp buzz_spec, do: %{spec() | command: "buzz"}

  # Absolute path: runnable without any overlay, for the isolation assertions.
  defp dump_spec(bin), do: %{spec() | command: Path.join(bin, "buzz")}

  defp env_pairs(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [name, value] -> [{name, value}]
        _no_assignment -> []
      end
    end)
    # `env` sets PWD/SHLVL/_ in the child regardless of what was passed in.
    |> Enum.reject(fn {name, _value} -> name in ~w(PWD SHLVL _) end)
  end

  defp env_value(output, name) do
    case output |> env_pairs() |> List.keyfind(name, 0) do
      {_name, value} -> value
      nil -> nil
    end
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
