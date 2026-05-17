defmodule FermixCore.Sandbox.CommandTool do
  @moduledoc """
  Executor for operator-declared local command capabilities.
  """

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.Env
  alias FermixCore.Sandbox.Mode

  @spec execute(map(), map(), Config.command_spec()) :: {:ok, Tool.tool_result()}
  def execute(args, context, spec) when is_map(args) and is_map(context) and is_map(spec) do
    with {:ok, prompt} <- required_prompt(args),
         {:ok, extra_args} <- optional_args(args),
         {:ok, env} <- Env.build_command(config_from(context), spec.pass_env),
         {:ok, cwd} <- working_dir(config_from(context)),
         {:ok, output} <- run_command(spec, prompt, extra_args, cwd, env) do
      {:ok, Tool.success(output)}
    else
      {:error, reason} -> {:ok, Tool.error(format_error(reason))}
    end
  end

  defp required_prompt(%{"prompt" => prompt}) when is_binary(prompt) and prompt != "",
    do: {:ok, prompt}

  defp required_prompt(_args), do: {:error, "Missing required parameter: prompt"}

  defp optional_args(%{"args" => args}) when is_list(args) do
    if Enum.all?(args, &is_binary/1), do: {:ok, args}, else: {:error, "args must be strings"}
  end

  defp optional_args(_args), do: {:ok, []}

  defp working_dir(config) do
    dir = Mode.default_working_dir(config)

    if File.dir?(dir), do: {:ok, dir}, else: {:error, {:missing_working_dir, dir}}
  end

  defp run_command(spec, prompt, extra_args, cwd, env) do
    argv = spec.args ++ extra_args ++ [prompt]

    task =
      Task.async(fn ->
        system_cmd(env_args(env, spec.command, argv), cwd, spec.timeout_ms)
      end)

    case Task.yield(task, spec.timeout_ms) || Task.shutdown(task) do
      {:ok, {:ok, output, 0}} -> {:ok, output}
      {:ok, {:ok, output, code}} -> {:error, {:command_failed, code, output}}
      {:ok, {:error, reason}} -> {:error, reason}
      nil -> {:error, {:command_timeout, spec.timeout_ms}}
    end
  end

  defp system_cmd(argv, cwd, _timeout_ms) do
    {output, code} = System.cmd(env_binary(), argv, cd: cwd, stderr_to_stdout: true)
    {:ok, output, code}
  rescue
    error in ErlangError -> {:error, Exception.message(error)}
  end

  defp env_args(env, command, argv) do
    assignments = Enum.map(env, fn {name, value} -> "#{name}=#{value}" end)
    ["-i" | assignments] ++ [command | argv]
  end

  defp env_binary do
    System.find_executable("env") || "/usr/bin/env"
  end

  defp config_from(%{sandbox_config: config}), do: Config.normalize(config)
  defp config_from(_context), do: Config.current()

  defp format_error({:command_failed, code, output}),
    do: "Command failed (exit code #{code}):\n#{output}"

  defp format_error({:command_timeout, timeout}), do: "Command timed out after #{timeout}ms"
  defp format_error({:missing_working_dir, dir}), do: "Working directory does not exist: #{dir}"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: "Command capability failed: #{inspect(reason)}"
end
