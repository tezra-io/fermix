defmodule FermixCore.Tools.ShellTest do
  use ExUnit.Case, async: false

  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.PathPolicy
  alias FermixCore.Tools.Shell

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
