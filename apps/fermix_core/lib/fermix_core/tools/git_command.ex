defmodule FermixCore.Tools.GitCommand do
  @moduledoc false

  # Audit F-01 follow-up (shared boundary): even when the resolved repo path
  # is sandbox-checked, git accepts flags that escape the `cd: repo` boundary.
  # `--upload-pack`/`--receive-pack` run an arbitrary program for the transport
  # (argument-injection -> command execution); `--git-dir`/`--work-tree`/
  # `--exec-path`/`--output`/`--no-index` redirect git's view of the repo or
  # its I/O sink. Every git tool runs through this one chokepoint, so the
  # denylist lives here rather than in each caller — keeping git_read and
  # git_write from drifting apart (the asymmetry that left git_write exposed).
  #
  # git honors unambiguous *prefix abbreviations* of long options (verified:
  # `git pull --upload-pac=<cmd>` runs <cmd>), so matching is prefix-based on
  # the option token (the part before `=`), which also covers the exact and
  # `--flag=value` forms.
  @dangerous_flags ~w(
    --no-index
    --git-dir
    --work-tree
    --exec-path
    --output
    --output-directory
    --upload-pack
    --receive-pack
    --man-path
    --info-path
  )

  @spec run(String.t(), String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(repo, command, args) when is_binary(repo) and is_binary(command) and is_list(args) do
    with :ok <- validate_repo(repo),
         :ok <- validate_args(args),
         :ok <- validate_flags(args) do
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

  defp validate_flags(args) do
    Enum.reduce_while(args, :ok, fn arg, :ok ->
      if denied_flag?(arg) do
        {:halt,
         {:error, "git arg #{inspect(arg)} is rejected; it can escape sandbox containment"}}
      else
        {:cont, :ok}
      end
    end)
  end

  # Long options only. The token is the part before `=`; reject it when it is a
  # prefix of any dangerous flag (catches abbreviations, exact, and `=value`).
  # `--` (end-of-options) and short/positional args are never dangerous here.
  defp denied_flag?("--" <> rest = arg) when byte_size(rest) > 0 do
    token = arg |> String.split("=", parts: 2) |> hd()
    Enum.any?(@dangerous_flags, &String.starts_with?(&1, token))
  end

  defp denied_flag?(_arg), do: false
end
