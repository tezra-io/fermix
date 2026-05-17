defmodule FermixCore.Tools.GitWrite do
  @moduledoc """
  Mutating local git operations, excluding push.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Sandbox
  alias FermixCore.Tools.GitCommand
  alias FermixCore.Tools.Support

  @commands ~w(add commit checkout pull)

  @impl true
  def name, do: "git_write"

  @impl true
  def description,
    do: "Stage, commit, checkout, or pull changes. Push is deferred to M10 approval."

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["command"],
      properties: %{
        repo: %{type: "string", description: "Git repository path, default current directory."},
        command: %{type: "string", description: "One of: add, commit, checkout, pull. Not push."},
        args: %{type: "array", items: %{type: "string"}, description: "Structured git args."}
      }
    }
  end

  @impl true
  def when_to_use, do: "Stage, commit, checkout, or pull local git changes; never push."

  @impl true
  def examples do
    [%{args: %{"command" => "add", "args" => ["README.md"]}, note: "stage a file"}]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "unknown_command", description: "command is not in the mutating whitelist"},
      %{tag: "push_deferred", description: "push is not available until M10 approval flow"},
      %{tag: "git_failed", description: "git returned a non-zero exit code"}
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
         git_args = Support.optional_string_list(args, "args"),
         {:ok, repo_dir} <- Sandbox.working_dir(repo, :git_write, context),
         {:ok, repo_root} <- git_root(repo_dir),
         {:ok, _allowed_root} <- Sandbox.write_path(repo_root, :git_write, context),
         {:ok, output} <- GitCommand.run(repo_dir, command, git_args) do
      {:ok, Tool.success(output)}
    else
      {:error, reason} -> Support.error(format_error(reason))
    end
  end

  defp git_root(repo) do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], cd: repo, stderr_to_stdout: true) do
      {root, 0} -> {:ok, String.trim(root)}
      {output, code} -> {:error, "git_failed: rev-parse exited #{code}: #{output}"}
    end
  end

  defp validate_command("push") do
    {:error,
     "push_deferred: git_push lands in M10 with the approval flow; use shell only if explicitly authorized."}
  end

  defp validate_command(command) when command in @commands, do: :ok
  defp validate_command(command), do: {:error, "unknown_command: #{command}"}

  defp format_error({:outside_root, path}), do: "Sandbox denied git_write outside roots: #{path}"
  defp format_error({:protected_path, path}), do: "Sandbox denied protected path: #{path}"
  defp format_error({:blocked_root, path}), do: "Sandbox denied blocked root: #{path}"
  defp format_error(reason), do: reason
end
