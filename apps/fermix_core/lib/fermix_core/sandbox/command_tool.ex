defmodule FermixCore.Sandbox.CommandTool do
  @moduledoc """
  Executor for operator-declared local command capabilities.
  """

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.CommandRunner
  alias FermixCore.Sandbox
  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.Env
  alias FermixCore.Sandbox.Mode

  @spec execute(map(), map(), Config.command_spec()) :: {:ok, Tool.tool_result()}
  def execute(args, context, spec) when is_map(args) and is_map(context) and is_map(spec) do
    config = config_from(context)

    with {:ok, prompt} <- required_prompt(args),
         {:ok, extra_args} <- optional_args(args),
         {:ok, env} <- Env.build_command(config, spec.pass_env),
         {:ok, cwd} <- working_dir(config, context),
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

  defp working_dir(config, context) do
    dir = Mode.default_working_dir(config)
    request = %{operation: :command_capability, working_dir: dir}

    with true <- File.dir?(dir),
         :allow <- Sandbox.enforce(:exec, request, sandbox_context(context, config)) do
      {:ok, dir}
    else
      false -> {:error, {:missing_working_dir, dir}}
      {:deny, reason} -> {:error, reason}
    end
  end

  defp run_command(spec, prompt, extra_args, cwd, env) do
    argv = spec.args ++ extra_args ++ [prompt]

    case CommandRunner.run(env_binary(), env_args(env, spec.command, argv),
           cwd: cwd,
           timeout_ms: spec.timeout_ms
         ) do
      {:ok, %{exit: 0, stdout: output}} -> {:ok, output}
      {:ok, %{exit: code, stdout: output}} -> {:error, {:command_failed, code, output}}
      {:error, {:timeout, ms}} -> {:error, {:command_timeout, ms}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp env_args(env, command, argv) do
    assignments = Enum.map(env, fn {name, value} -> "#{name}=#{value}" end)
    ["-i" | assignments] ++ [command | argv]
  end

  defp env_binary do
    System.find_executable("env") || "/usr/bin/env"
  end

  defp sandbox_context(context, config), do: Map.put(context, :sandbox_config, config)
  defp config_from(%{sandbox_config: config}), do: Config.normalize(config)
  defp config_from(_context), do: Config.current()

  defp format_error({:command_failed, code, output}),
    do: "Command failed (exit code #{code}):\n#{output}"

  defp format_error({:command_timeout, timeout}), do: "Command timed out after #{timeout}ms"
  defp format_error({:missing_working_dir, dir}), do: "Working directory does not exist: #{dir}"

  defp format_error({:outside_root, path}),
    do:
      "Sandbox denied command capability working_dir outside roots: #{path}. " <>
        "To allow this directory, run: fermix grant path #{path}"

  defp format_error({:protected_path, path}),
    do: "Sandbox denied protected path: #{path}. Run: fermix sandbox explain"

  defp format_error({:blocked_root, path}),
    do: "Sandbox denied blocked root: #{path}. Run: fermix sandbox explain"

  defp format_error({:env_not_allowed, _name} = reason), do: Env.format_error(reason)
  defp format_error({:env_denied, _name} = reason), do: Env.format_error(reason)
  defp format_error({:missing_env, _name} = reason), do: Env.format_error(reason)
  defp format_error({:env_command_failed, _command, _code, _output} = reason), do: Env.format_error(reason)
  defp format_error({:env_command_timeout, _command, _timeout} = reason), do: Env.format_error(reason)
  defp format_error(:env_command_output_too_large), do: Env.format_error(:env_command_output_too_large)
  defp format_error(:empty_env_command_output), do: Env.format_error(:empty_env_command_output)
  defp format_error(:env_command_output_not_single_value), do: Env.format_error(:env_command_output_not_single_value)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: "Command capability failed: #{inspect(reason)}"
end
