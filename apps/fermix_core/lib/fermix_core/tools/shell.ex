defmodule FermixCore.Tools.Shell do
  @moduledoc """
  Execute shell commands. Supports working directory, timeout, and stderr capture.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Sandbox

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
          description: "Working directory (defaults to the sandbox mode working directory)"
        },
        timeout_ms: %{
          type: "integer",
          description: "Timeout in milliseconds (default: 30000)"
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "Run a shell command only when no narrower Fermix built-in capability owns the verb."
  end

  @impl true
  def examples do
    [%{args: %{"command" => "mix test", "timeout_ms" => 120_000}, note: "run a repo command"}]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "invalid_command", description: "command is absent or blank"},
      %{tag: "invalid_working_dir", description: "working_dir does not exist"},
      %{tag: "sandbox_denied", description: "working_dir is outside sandbox roots or protected"},
      %{tag: "sandbox_hardline", description: "command matches the hardline denylist"},
      %{tag: "timeout", description: "command exceeded timeout_ms"},
      %{tag: "exit_nonzero", description: "command exited with a non-zero code"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :system

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    agent = Map.get(context, :agent_name, "unknown")

    result = do_execute(args, context)

    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    :telemetry.execute(
      [:fermix, :tool, :exec],
      %{duration_ms: duration},
      %{tool: "shell", agent: agent, success: success}
    )

    result
  end

  defp do_execute(args, context) do
    with {:ok, command} <- Map.fetch(args, "command") do
      working_dir = Map.get(args, "working_dir")
      timeout = Map.get(args, "timeout_ms", @default_timeout_ms)

      with :ok <- validate_command(command),
           {:ok, plan} <- Sandbox.shell_plan(command, working_dir, context) do
        run_command(command, plan.working_dir, timeout, plan.env)
      else
        {:error, reason} -> {:ok, Tool.error(format_error(reason))}
      end
    else
      :error -> {:ok, Tool.error("Missing required parameter: command")}
    end
  end

  defp validate_command(command) when is_binary(command) and byte_size(command) > 0, do: :ok
  defp validate_command(_), do: {:error, "Command must be a non-empty string"}

  defp run_command(command, working_dir, timeout, env) do
    task =
      Task.async(fn ->
        System.cmd(env_binary(), env_args(env, command), cd: working_dir, stderr_to_stdout: true)
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

  defp env_args(env, command) do
    assignments = Enum.map(env, fn {name, value} -> "#{name}=#{value}" end)
    ["-i" | assignments] ++ ["sh", "-c", command]
  end

  defp env_binary do
    System.find_executable("env") || "/usr/bin/env"
  end

  defp format_error({:hardline, reason}), do: "Sandbox hardline blocked command: #{reason}"
  defp format_error({:missing_working_dir, dir}), do: "Working directory does not exist: #{dir}"

  defp format_error({:outside_root, path}),
    do:
      "Sandbox denied shell working_dir outside roots: #{path}. " <>
        "To allow this directory, run: fermix grant path #{path}"

  defp format_error({:protected_path, path}),
    do:
      "Sandbox denied protected path: #{path}. " <>
        "Run: fermix sandbox explain"

  defp format_error({:blocked_root, path}),
    do:
      "Sandbox denied blocked root: #{path}. " <>
        "Run: fermix sandbox explain"

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: "Sandbox denied shell command: #{inspect(reason)}"
end
