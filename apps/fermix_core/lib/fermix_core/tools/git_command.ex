defmodule FermixCore.Tools.GitCommand do
  @moduledoc false

  @spec run(String.t(), String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(repo, command, args) when is_binary(repo) and is_binary(command) and is_list(args) do
    with :ok <- validate_repo(repo),
         :ok <- validate_args(args) do
      case System.cmd("git", [command | args], cd: repo, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, exit_code} -> {:error, "git #{command} failed (exit #{exit_code}):\n#{output}"}
      end
    end
  end

  defp validate_repo(repo) do
    cond do
      String.contains?(repo, "\0") -> {:error, "repo contains null bytes"}
      not File.dir?(repo) -> {:error, "repo does not exist: #{repo}"}
      true -> :ok
    end
  end

  defp validate_args(args) do
    if Enum.all?(args, &(is_binary(&1) and not String.contains?(&1, "\0"))) do
      :ok
    else
      {:error, "git args must be strings without null bytes"}
    end
  end
end
