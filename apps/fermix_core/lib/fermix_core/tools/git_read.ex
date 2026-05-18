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
         {:ok, output} <- GitCommand.run(resolved_repo, command, git_args) do
      {:ok, Tool.success(output)}
    else
      {:error, reason} -> Support.error(reason)
    end
  end

  defp validate_command(command) when command in @commands, do: :ok
  defp validate_command(command), do: {:error, "unknown_command: #{command}"}
end
