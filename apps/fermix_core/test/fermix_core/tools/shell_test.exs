defmodule FermixCore.Tools.ShellTest do
  use ExUnit.Case, async: true

  alias FermixCore.Tools.Shell

  @context %{agent_name: "test_agent", conversation_key: :test}

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
      dir = Path.join(System.tmp_dir!(), "fermix_shell_wd_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      assert {:ok, result} =
               Shell.execute(%{"command" => "pwd -P", "working_dir" => dir}, @context)

      assert result.success == true

      # Resolve physical path for comparison (macOS symlinks /tmp -> /private/tmp)
      {expected, 0} = System.cmd("pwd", ["-P"], cd: dir)
      assert String.trim(result.output) == String.trim(expected)

      File.rm_rf!(dir)
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
      bad_dir = "/nonexistent_fermix_dir_#{System.unique_integer([:positive])}"

      assert {:ok, result} =
               Shell.execute(%{"command" => "echo hi", "working_dir" => bad_dir}, @context)

      assert result.success == false
      assert result.error =~ "Working directory"
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
end
