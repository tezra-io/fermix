defmodule FermixCore.Tools.Shell do
  @moduledoc """
  Execute shell commands. Supports working directory, timeout, and stderr capture.
  """

  @behaviour FermixCore.Tools.Tool

  alias FermixCore.Tools.Tool

  @default_timeout_ms 30_000

  @impl true
  @spec name() :: String.t()
  def name, do: "shell"

  @impl true
  @spec description() :: String.t()
  def description do
    "Execute a shell command and return its output. " <>
      "Use for file operations, git commands, system queries, etc."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["command"],
      properties: %{
        command: %{
          type: "string",
          description: "The shell command to execute"
        },
        working_dir: %{
          type: "string",
          description: "Working directory (defaults to current directory)"
        },
        timeout_ms: %{
          type: "integer",
          description: "Timeout in milliseconds (default: 30000)"
        }
      }
    }
  end

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    agent = Map.get(context, :agent_name, "unknown")

    result = do_execute(args)

    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    :telemetry.execute(
      [:fermix, :tool, :exec],
      %{duration_ms: duration},
      %{tool: "shell", agent: agent, success: success}
    )

    result
  end

  defp do_execute(args) do
    command = Map.fetch!(args, "command")
    working_dir = Map.get(args, "working_dir", File.cwd!())
    timeout = Map.get(args, "timeout_ms", @default_timeout_ms)

    with :ok <- validate_command(command),
         :ok <- validate_working_dir(working_dir) do
      run_command(command, working_dir, timeout)
    else
      {:error, reason} -> {:ok, Tool.error(reason)}
    end
  end

  defp validate_command(command) when is_binary(command) and byte_size(command) > 0, do: :ok
  defp validate_command(_), do: {:error, "Command must be a non-empty string"}

  defp validate_working_dir(dir) do
    if File.dir?(dir) do
      :ok
    else
      {:error, "Working directory does not exist: #{dir}"}
    end
  end

  defp run_command(command, working_dir, timeout) do
    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", command], cd: working_dir, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {output, 0}} ->
        {:ok, Tool.success(output)}

      {:ok, {output, exit_code}} ->
        {:ok, Tool.error("Command failed (exit code #{exit_code}):\n#{output}")}

      nil ->
        {:ok, Tool.error("Command timed out after #{timeout}ms")}
    end
  end
end
