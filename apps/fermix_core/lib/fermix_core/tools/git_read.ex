defmodule FermixCore.Tools.GitRead do
  @moduledoc """
  Read-only git operations.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Sandbox
  alias FermixCore.Tools.GitCommand
  alias FermixCore.Tools.Support

  @commands ~w(status log diff branch show)

  # Audit F-01 follow-up: even though the resolved repo path is
  # sandbox-checked, git accepts a handful of flags that escape the
  # `cd: repo` boundary and read arbitrary host paths. `--no-index`
  # turns `git diff` into a path-pair comparator that ignores the
  # working tree. `--git-dir`, `--work-tree`, `-C`, `--exec-path`,
  # `--output`, and `--upload-pack` redirect git's view of the repo
  # or its output sink. Absolute-path positional args are similarly
  # outside the sandbox. Reject all of these at the tool boundary
  # before they reach `git`.
  @arg_flag_denylist ~w(
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
  @arg_flag_prefix_denylist ~w(
    --git-dir=
    --work-tree=
    --exec-path=
    --output=
    --output-directory=
    --upload-pack=
    --receive-pack=
  )

  @impl true
  def name, do: "git_read"

  @impl true
  def description, do: "Inspect git status, logs, branches, diffs, and objects."

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["command"],
      properties: %{
        repo: %{type: "string", description: "Git repository path, default current directory."},
        command: %{type: "string", description: "One of: status, log, diff, branch, show."},
        args: %{type: "array", items: %{type: "string"}, description: "Structured git args."}
      }
    }
  end

  @impl true
  def when_to_use, do: "Inspect git state with status, log, diff, branch, or show."

  @impl true
  def examples,
    do: [%{args: %{"command" => "status", "args" => ["--short"]}, note: "short git status"}]

  @impl true
  def failure_modes do
    [
      %{tag: "unknown_command", description: "command is not in the read-only whitelist"},
      %{tag: "git_failed", description: "git returned a non-zero exit code"},
      %{tag: "invalid_repo", description: "repo path is missing or not a directory"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :git

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> do_execute(args, context) end)
  end

  defp do_execute(args, context) do
    with {:ok, command} <- Support.required_string(args, "command"),
         :ok <- validate_command(command),
         repo = Map.get(args, "repo", File.cwd!()),
         {:ok, resolved_repo} <- Sandbox.read_path(repo, :git_read, context),
         git_args = Support.optional_string_list(args, "args"),
         :ok <- validate_args(git_args),
         {:ok, output} <- GitCommand.run(resolved_repo, command, git_args) do
      {:ok, Tool.success(output)}
    else
      {:error, reason} -> Support.error(reason)
    end
  end

  defp validate_command(command) when command in @commands, do: :ok
  defp validate_command(command), do: {:error, "unknown_command: #{command}"}

  defp validate_args(args) do
    Enum.reduce_while(args, :ok, fn arg, :ok ->
      case classify_arg(arg) do
        :ok -> {:cont, :ok}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
  end

  defp classify_arg(arg) when not is_binary(arg),
    do: {:error, "git args must be strings"}

  defp classify_arg(arg) do
    cond do
      arg in @arg_flag_denylist ->
        {:error, "git arg #{inspect(arg)} is rejected; it can escape sandbox containment"}

      Enum.any?(@arg_flag_prefix_denylist, &String.starts_with?(arg, &1)) ->
        {:error, "git arg #{inspect(arg)} is rejected; it can escape sandbox containment"}

      absolute_path_arg?(arg) ->
        {:error, "git arg #{inspect(arg)} is an absolute path; pass repo-relative paths only"}

      path_traversal_arg?(arg) ->
        {:error, "git arg #{inspect(arg)} resolves outside the repo via `..`"}

      true ->
        :ok
    end
  end

  # Flags begin with `-`. Anything else is a positional arg (paths, refs,
  # commit-ish). Refs can contain `/` (`refs/heads/main`); paths can too.
  # We block absolute paths but accept refs by ignoring forward-slash
  # contents that are not absolute.
  defp absolute_path_arg?("-" <> _flag), do: false
  defp absolute_path_arg?("/" <> _path), do: true
  defp absolute_path_arg?("~/" <> _path), do: true
  defp absolute_path_arg?(_arg), do: false

  defp path_traversal_arg?("-" <> _flag), do: false

  defp path_traversal_arg?(arg) do
    arg |> Path.split() |> Enum.any?(&(&1 == ".."))
  end
end
