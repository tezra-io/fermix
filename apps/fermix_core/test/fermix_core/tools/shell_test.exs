defmodule FermixCore.Tools.ShellTest do
  use ExUnit.Case, async: false

  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.Env
  alias FermixCore.Sandbox.EnvHealth
  alias FermixCore.Sandbox.PathPolicy
  alias FermixCore.Tools.Shell
  alias FermixTestSupport.RunnerCallTrace

  @context %{agent_name: "test_agent", conversation_key: :test}

  setup do
    sandbox = Application.get_env(:fermix_core, :sandbox)
    previous_home = System.get_env("FERMIX_HOME")
    home = FermixTestSupport.SafeRm.make_tmp_dir!("shell-home")
    workspace = Path.join(home, "workspace")
    File.mkdir_p!(workspace)

    System.put_env("FERMIX_HOME", home)

    Application.put_env(
      :fermix_core,
      :sandbox,
      Config.normalize(mode: :strict, workspace_root: workspace)
    )

    on_exit(fn ->
      case sandbox do
        nil -> Application.delete_env(:fermix_core, :sandbox)
        value -> Application.put_env(:fermix_core, :sandbox, value)
      end

      case previous_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      FermixTestSupport.SafeRm.rm_rf!(home)
    end)

    :ok
  end

  describe "name/0" do
    test "returns shell" do
      assert Shell.name() == "shell"
    end
  end

  describe "description/0" do
    test "returns a non-empty string" do
      desc = Shell.description()
      assert is_binary(desc)
      assert byte_size(desc) > 0
    end
  end

  describe "parameters/0" do
    test "returns JSON Schema with command as required" do
      params = Shell.parameters()
      assert params.type == "object"
      assert "command" in params.required
      assert Map.has_key?(params.properties, :command)
    end

    test "includes optional working_dir and timeout_ms" do
      params = Shell.parameters()
      assert Map.has_key?(params.properties, :working_dir)
      assert Map.has_key?(params.properties, :timeout_ms)
    end
  end

  describe "execute/2 - happy path" do
    test "runs command and returns stdout" do
      assert {:ok, result} = Shell.execute(%{"command" => "echo hello"}, @context)
      assert result.success == true
      assert String.trim(result.output) == "hello"
      assert result.error == nil
    end

    test "captures stderr merged into stdout" do
      assert {:ok, result} = Shell.execute(%{"command" => "echo err >&2"}, @context)
      assert result.success == true
      assert String.contains?(result.output, "err")
    end

    test "uses specified working directory" do
      dir = FermixTestSupport.SafeRm.make_tmp_dir!("shell-wd")
      context = sandbox_context(mode: :strict, workspace_root: dir)

      assert {:ok, result} =
               Shell.execute(%{"command" => "pwd -P", "working_dir" => dir}, context)

      assert result.success == true

      # Resolve physical path for comparison (macOS symlinks /tmp -> /private/tmp)
      {expected, 0} = System.cmd("pwd", ["-P"], cd: dir)
      assert String.trim(result.output) == String.trim(expected)

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end

    test "defaults cwd to the sandbox workspace" do
      dir = FermixTestSupport.SafeRm.make_tmp_dir!("shell-default")
      context = sandbox_context(mode: :strict, workspace_root: dir)

      assert {:ok, result} = Shell.execute(%{"command" => "pwd -P"}, context)
      assert result.success == true

      {expected, 0} = System.cmd("pwd", ["-P"], cd: dir)
      assert String.trim(result.output) == String.trim(expected)

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end
  end

  describe "execute/2 - error cases" do
    test "returns error for non-zero exit code" do
      assert {:ok, result} = Shell.execute(%{"command" => "exit 1"}, @context)
      assert result.success == false
      assert result.error =~ "exit code"
    end

    test "returns error for empty command" do
      assert {:ok, result} = Shell.execute(%{"command" => ""}, @context)
      assert result.success == false
      assert result.error =~ "non-empty"
    end

    test "returns error for invalid working directory" do
      root = FermixTestSupport.SafeRm.make_tmp_dir!("shell-root")
      bad_dir = Path.join(root, "missing")
      context = sandbox_context(mode: :strict, workspace_root: root)

      assert {:ok, result} =
               Shell.execute(%{"command" => "echo hi", "working_dir" => bad_dir}, context)

      assert result.success == false
      assert result.error =~ "Working directory"

      FermixTestSupport.SafeRm.rm_rf!(root)
    end

    test "returns error for working directory outside sandbox roots" do
      root = FermixTestSupport.SafeRm.make_tmp_dir!("shell-root")
      outside = FermixTestSupport.SafeRm.make_tmp_dir!("shell-outside")
      context = sandbox_context(mode: :strict, workspace_root: root)

      assert {:ok, result} =
               Shell.execute(%{"command" => "echo hi", "working_dir" => outside}, context)

      assert result.success == false
      assert result.error =~ "outside roots"
      assert result.error =~ "fermix grant path #{PathPolicy.canonical_path(outside)}"

      FermixTestSupport.SafeRm.rm_rf!(root)
      FermixTestSupport.SafeRm.rm_rf!(outside)
    end
  end

  describe "execute/2 - input validation" do
    test "returns error for missing command parameter" do
      assert {:ok, result} = Shell.execute(%{}, @context)
      assert result.success == false
      assert result.error =~ "Missing"
    end

    test "handles commands with special characters" do
      assert {:ok, result} = Shell.execute(%{"command" => "echo 'hello world'"}, @context)
      assert result.success == true
      assert String.trim(result.output) == "hello world"
    end

    test "handles commands with pipes" do
      assert {:ok, result} = Shell.execute(%{"command" => "echo hello | tr 'h' 'H'"}, @context)
      assert result.success == true
      assert String.trim(result.output) == "Hello"
    end
  end

  describe "execute/2 - timeout" do
    test "returns error when command exceeds timeout" do
      args = %{"command" => "sleep 10", "timeout_ms" => 200}
      assert {:ok, result} = Shell.execute(args, @context)
      assert result.success == false
      assert result.error =~ "timed out"
    end
  end

  describe "telemetry" do
    test "emits [:fermix, :tool, :exec] event on success" do
      handler_id = attach_telemetry()

      Shell.execute(%{"command" => "echo telemetry_test"}, @context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], measurements, metadata}
      assert is_integer(measurements.duration_ms)
      assert measurements.duration_ms >= 0
      assert metadata.tool == "shell"
      assert metadata.agent == "test_agent"
      assert metadata.success == true

      :telemetry.detach(handler_id)
    end

    test "emits [:fermix, :tool, :exec] event on failure" do
      handler_id = attach_telemetry()

      Shell.execute(%{"command" => "exit 1"}, @context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], measurements,
                      %{tool: "shell", agent: "test_agent", success: false}}

      assert is_integer(measurements.duration_ms)

      :telemetry.detach(handler_id)
    end

    test "includes bounded redacted command failure details" do
      handler_id = attach_telemetry()

      Shell.execute(
        %{"command" => "API_TOKEN=super-secret sh -c 'echo nope; exit 7'"},
        @context
      )

      assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements, metadata}
      assert metadata.success == false
      assert metadata.command =~ "API_TOKEN=[REDACTED]"
      refute metadata.command =~ "super-secret"
      assert metadata.exit_code == 7
      assert metadata.failure == "exit_nonzero"
      assert metadata.error_summary =~ "exit code 7"

      :telemetry.detach(handler_id)
    end

    test "emits telemetry even on validation error" do
      handler_id = attach_telemetry()

      Shell.execute(%{"command" => ""}, @context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], measurements, metadata}
      assert metadata.success == false
      assert metadata.tool == "shell"
      assert is_integer(measurements.duration_ms)

      :telemetry.detach(handler_id)
    end

    # Typed proof that policy stopped a command before it began. Free-form error
    # text is not proof — a command that genuinely ran and exited non-zero also
    # produces error text — so consumers key off this marker and nothing else.
    test "a hardline block carries typed pre-execution policy evidence" do
      handler_id = attach_telemetry()

      # Inert even if both the classifier and the assertion regress.
      Shell.execute(%{"command" => "dd if=/dev/zero of=/dev/null count=1"}, @context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements, metadata}
      assert metadata.success == false

      assert metadata.policy_enforcement == %{
               source: "sandbox",
               decision: "hardline",
               phase: "pre_execution"
             }

      :telemetry.detach(handler_id)
    end

    test "a working directory outside the sandbox roots is typed as a deny" do
      root = FermixTestSupport.SafeRm.make_tmp_dir!("shell-root")
      outside = FermixTestSupport.SafeRm.make_tmp_dir!("shell-outside")
      handler_id = attach_telemetry()

      Shell.execute(
        %{"command" => "echo hi", "working_dir" => outside},
        sandbox_context(mode: :strict, workspace_root: root)
      )

      assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements, metadata}

      assert metadata.policy_enforcement == %{
               source: "sandbox",
               decision: "deny",
               phase: "pre_execution"
             }

      :telemetry.detach(handler_id)
      FermixTestSupport.SafeRm.rm_rf!(root)
      FermixTestSupport.SafeRm.rm_rf!(outside)
    end

    # The negative case is what keeps the marker honest: a command that actually
    # executed must never look like a blocked one.
    test "a command that ran and failed carries no policy evidence" do
      handler_id = attach_telemetry()

      Shell.execute(%{"command" => "exit 1"}, @context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements, metadata}
      assert metadata.success == false
      refute Map.has_key?(metadata, :policy_enforcement)

      :telemetry.detach(handler_id)
    end

    test "a missing working directory is not a policy denial" do
      root = FermixTestSupport.SafeRm.make_tmp_dir!("shell-root")
      handler_id = attach_telemetry()

      Shell.execute(
        %{"command" => "echo hi", "working_dir" => Path.join(root, "missing")},
        sandbox_context(mode: :strict, workspace_root: root)
      )

      assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements, metadata}
      assert metadata.success == false
      assert metadata.failure == "missing_working_dir"
      refute Map.has_key?(metadata, :policy_enforcement)

      :telemetry.detach(handler_id)
      FermixTestSupport.SafeRm.rm_rf!(root)
    end

    # One allowed variable the daemon cannot read is not a reason to refuse a
    # command that never asked for it. The command runs, the result names the
    # variable and the remedy where the model reads it, and the trace carries
    # the names only, so a content-free export still shows what was missing.
    test "a command still runs when an allowed variable cannot be resolved, and says so" do
      handler_id = attach_telemetry()
      config = allow_absent_variable()

      assert {:ok, result} =
               Shell.execute(
                 %{"command" => "printf ran"},
                 Map.put(@context, :sandbox_config, config)
               )

      assert result.success == true
      assert result.output =~ "ran"
      assert result.output =~ "FERMIX_TEST_ABSENT has no value Fermix can read"
      assert result.output =~ Env.missing_env_remedy()

      assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements, metadata}
      assert metadata.success == true
      assert metadata.env_unresolved == ["FERMIX_TEST_ABSENT"]
      refute Map.has_key?(metadata, :policy_enforcement)

      :telemetry.detach(handler_id)
    end

    # The trace summary stays the command's own words: a reader matching on the
    # exit line must not hit the notice first, and `env_unresolved` already
    # carries the machine-readable claim.
    test "a failing command carries the notice for the model, not in its trace summary" do
      handler_id = attach_telemetry()
      config = allow_absent_variable()

      assert {:ok, result} =
               Shell.execute(
                 %{"command" => "test -n \"$FERMIX_TEST_ABSENT\""},
                 Map.put(@context, :sandbox_config, config)
               )

      assert result.success == false
      assert result.error =~ "FERMIX_TEST_ABSENT has no value Fermix can read"
      assert result.error =~ "exit code 1"

      assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements, metadata}
      assert metadata.error_summary =~ "exit code 1"
      refute metadata.error_summary =~ "has no value Fermix can read"
      assert metadata.env_unresolved == ["FERMIX_TEST_ABSENT"]

      :telemetry.detach(handler_id)
    end

    test "a command whose allowed variables all resolve carries no notice" do
      handler_id = attach_telemetry()

      Shell.execute(%{"command" => "printf ran"}, @context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements, metadata}
      assert metadata.success == true
      refute Map.has_key?(metadata, :env_unresolved)

      :telemetry.detach(handler_id)
    end
  end

  # M45 §4.6 and §4.7. An allowed variable's value reaches the command as its
  # environment and nowhere else: not as argv, where any process on the host
  # can read it, and not in anything the model or a trace sees, where an echo
  # would carry it out of the machine.
  # A synthetic fixture read through a `command` source, the shape a stored
  # credential has, so no test reads the operator's keychain or environment.
  @token_name "FERMIX_TEST_M45_TOKEN"
  @token "m45Qz-fixture-token-7781"

  describe "an allowed credential" do
    setup do
      prior = Application.get_env(:fermix_core, :telemetry, [])
      on_exit(fn -> Application.put_env(:fermix_core, :telemetry, prior) end)

      session = "m45-shell-#{System.unique_integer([:positive])}"
      handler = attach_session_telemetry(session)
      on_exit(fn -> :telemetry.detach(handler) end)

      context =
        @context
        |> Map.put(:session_id, session)
        |> Map.put(:sandbox_config, credential_config())

      %{context: context, session: session, prior: prior}
    end

    test "reaches the shell as its environment and never as argv", ctx do
      RunnerCallTrace.start()

      assert {:ok, %{success: true}} = Shell.execute(%{"command" => "printf ok"}, ctx.context)

      {executable, args, opts} = RunnerCallTrace.call_with("printf ok")
      assert Path.basename(executable) == "sh"
      assert args == ["-c", "printf ok"]
      refute Enum.any?([executable | args], &String.contains?(&1, @token))
      assert Keyword.fetch!(opts, :env_mode) == :replace
      assert {@token_name, @token} in Keyword.fetch!(opts, :env)
    end

    for capture <- [true, false] do
      test "an echoed value is redacted from a successful result (capture #{capture})", ctx do
        set_capture_content(ctx.prior, unquote(capture))

        assert {:ok, result} =
                 Shell.execute(%{"command" => ~s(printf '%s' "$#{@token_name}")}, ctx.context)

        assert result.success == true
        assert result.output == "«redacted»"

        session = ctx.session
        assert_receive {:shell_event, %{session_id: ^session} = metadata}
        refute inspect(metadata) =~ @token
        if unquote(capture), do: assert(metadata.output == "«redacted»")
      end

      test "an echoed value is redacted from a failed result (capture #{capture})", ctx do
        set_capture_content(ctx.prior, unquote(capture))
        command = ~s(printf '%s' "$#{@token_name}"; exit 3)

        assert {:ok, result} = Shell.execute(%{"command" => command}, ctx.context)

        assert result.success == false
        assert result.error =~ "exit code 3"
        assert result.error =~ "«redacted»"
        refute result.error =~ @token

        session = ctx.session
        assert_receive {:shell_event, %{session_id: ^session} = metadata}
        assert metadata.error_summary =~ "«redacted»"
        refute inspect(metadata) =~ @token
        if unquote(capture), do: assert(metadata.output =~ "«redacted»")
      end
    end

    # The trace summary is cut to a bounded length. Scrubbing after that cut
    # would miss a value the cut split in two and export its first half.
    test "the value is scrubbed before the trace summary is truncated", ctx do
      set_capture_content(ctx.prior, false)
      # "Command failed (exit code 3):\n" is 30 bytes, so the value starts five
      # bytes before the summary's 500-byte cut.
      padding = String.duplicate("x", 465)
      command = ~s(printf '%s%s' "#{padding}" "$#{@token_name}"; exit 3)

      assert {:ok, %{success: false}} = Shell.execute(%{"command" => command}, ctx.context)

      session = ctx.session
      assert_receive {:shell_event, %{session_id: ^session} = metadata}
      refute metadata.error_summary =~ binary_part(@token, 0, 5)
    end

    # The default keys are the child's ordinary environment, not credentials.
    test "a default key such as HOME is not redacted", ctx do
      home = System.get_env("HOME")

      assert {:ok, %{success: true, output: output}} =
               Shell.execute(%{"command" => ~s(printf '%s' "$HOME")}, ctx.context)

      assert output == home
    end
  end

  defp credential_config do
    Config.normalize(
      mode: :strict,
      workspace_root: Config.current().workspace_root,
      env: [
        allow: [@token_name],
        sources: %{
          @token_name => [source: :command, command: "/bin/echo", args: [@token]]
        }
      ]
    )
  end

  defp set_capture_content(prior, value) do
    Application.put_env(:fermix_core, :telemetry, Keyword.put(prior, :capture_content, value))
  end

  # Pinned to one session id: a global handler must not read another test's event.
  defp attach_session_telemetry(session) do
    handler = "test-shell-m45-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:fermix, :tool, :exec],
      fn _event, _measurements, metadata, _config ->
        if metadata[:session_id] == session, do: send(test_pid, {:shell_event, metadata})
      end,
      nil
    )

    handler
  end

  # Establishes an allowed variable the daemon cannot read, and puts back both
  # the OS variable and the shared health record when the test is over.
  defp allow_absent_variable do
    original = System.get_env("FERMIX_TEST_ABSENT")
    System.delete_env("FERMIX_TEST_ABSENT")

    on_exit(fn ->
      EnvHealth.record(%{resolved: ["FERMIX_TEST_ABSENT"], unresolved: []})

      case original do
        nil -> System.delete_env("FERMIX_TEST_ABSENT")
        value -> System.put_env("FERMIX_TEST_ABSENT", value)
      end
    end)

    current = Config.current()
    %{current | env: %{current.env | allow: ["FERMIX_TEST_ABSENT"]}}
  end

  defp attach_telemetry do
    handler_id = "test-shell-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:fermix, :tool, :exec],
      fn event, measurements, metadata, _config ->
        if metadata.tool == "shell" do
          send(test_pid, {:telemetry, event, measurements, metadata})
        end
      end,
      nil
    )

    handler_id
  end

  defp sandbox_context(config) do
    Map.put(@context, :sandbox_config, Config.normalize(config))
  end
end
