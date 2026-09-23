defmodule FermixCore.Sandbox.CommandToolTest do
  use ExUnit.Case, async: false

  alias FermixCore.Sandbox.CommandTool
  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.Env
  alias FermixCore.Sandbox.PathPolicy
  alias FermixTestSupport.RunnerCallTrace

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

  # M45 §4.6 and §4.7 for operator command capabilities: a `pass_env` value
  # reaches the command as its environment, never as argv, and an echo of it
  # never reaches the model.
  describe "a pass_env credential" do
    @token_name "FERMIX_TEST_M45_TOKEN"
    @token "m45Qz-fixture-token-7781"

    setup do
      root = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-command-tool-credential")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)

      config =
        Config.normalize(
          mode: :open,
          workspace_root: root,
          allowed_roots: [root],
          env: [
            allow: [@token_name],
            sources: %{
              @token_name => [source: :command, command: "/bin/echo", args: [@token]]
            }
          ]
        )

      %{context: %{sandbox_config: config}}
    end

    test "reaches the command as its environment and never as argv", ctx do
      RunnerCallTrace.start()

      assert {:ok, %{success: true}} =
               CommandTool.execute(%{"prompt" => "argv-marker"}, ctx.context, sh_spec("true"))

      {executable, args, opts} = RunnerCallTrace.call_with("argv-marker")
      assert executable == "/bin/sh"
      assert args == ["-c", "true", "argv-marker"]
      refute Enum.any?([executable | args], &String.contains?(&1, @token))
      assert Keyword.fetch!(opts, :env_mode) == :replace
      assert {@token_name, @token} in Keyword.fetch!(opts, :env)
    end

    test "an echoed value is redacted from a successful result", ctx do
      spec = sh_spec(~s(printf '%s' "$#{@token_name}"))

      assert {:ok, %{success: true, output: output}} =
               CommandTool.execute(%{"prompt" => "ignored"}, ctx.context, spec)

      assert output == "«redacted»"
    end

    test "an echoed value is redacted from a failed result", ctx do
      spec = sh_spec(~s(printf '%s' "$#{@token_name}"; exit 4))

      assert {:ok, %{success: false, error: error}} =
               CommandTool.execute(%{"prompt" => "ignored"}, ctx.context, spec)

      assert error =~ "exit code 4"
      assert error =~ "«redacted»"
      refute error =~ @token
    end
  end

  # `sh -c SCRIPT PROMPT`: the prompt arrives as `$0`, so the script decides
  # what the command prints and how it exits.
  defp sh_spec(script),
    do: %{spec() | command: "/bin/sh", args: ["-c", script], pass_env: [@token_name]}

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
      # Every test here asserts what the command printed and saw, never how
      # fast it was spawned, so the budget only has to outlast a loaded host:
      # a second was not enough for two spawns while the suite ran beside
      # other work on the same Mac.
      timeout_ms: 30_000,
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
