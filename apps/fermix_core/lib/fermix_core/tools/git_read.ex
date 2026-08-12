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

  # `branch` is the one read command with mutating modes, and the sharpest of
  # them needs no flag at all: `git branch <name>` CREATES a ref. So the
  # invariant is "branch mode takes flags only" rather than a denylist of the
  # destructive spellings — a denylist would still let a bare operand through.
  # The named modes are listed as well, so a caller reaching for `-D` is told
  # what the rule is instead of being refused for the operand it happened to
  # carry. A `:read_only` capability must never modify or delete a ref.
  #
  # The cost is that a flag VALUE cannot be a separate arg; git accepts the `=`
  # form for all of them (`--contains=HEAD`, `--merged=main`), which the
  # refusal names.
  @branch_mutating_flags ~w(
    --delete --move --copy --force
    --set-upstream --set-upstream-to --unset-upstream --edit-description
  )
  @branch_mutating_short ~w(-d -D -m -M -c -C -f -u)

  # Audit F-01 follow-up: dangerous git *flags* that escape the `cd: repo`
  # boundary (`--upload-pack`, `--git-dir`, `--no-index`, ...) are rejected at
  # the shared chokepoint in `FermixCore.Tools.GitCommand`, so every git tool
  # is covered uniformly. Here we additionally reject *positional* args that
  # point outside the repo — absolute paths and `..` traversal — a read-tool
  # concern (mutating tools pass free-text like commit messages that may
  # legitimately resemble paths, so they do not apply this positional check).

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
      %{tag: "invalid_repo", description: "repo path is missing or not a directory"},
      %{
        tag: "branch_writes_refused",
        description:
          "branch mode lists only: flags that modify refs and bare operands are refused. " <>
            "Pass a flag value in the = form, e.g. --contains=HEAD"
      }
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
         :ok <- validate_branch_mode(command, git_args),
         {:ok, output} <- GitCommand.run(resolved_repo, command, git_args) do
      {:ok, Tool.success(output)}
    else
      {:error, reason} -> Support.error(reason)
    end
  end

  defp validate_command(command) when command in @commands, do: :ok
  defp validate_command(command), do: {:error, "unknown_command: #{command}"}

  defp validate_branch_mode("branch", args) do
    Enum.reduce_while(args, :ok, fn arg, :ok ->
      case classify_branch_arg(arg) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_branch_mode(_command, _args), do: :ok

  defp classify_branch_arg("-" <> _rest = arg) do
    if branch_mutating_flag?(arg) do
      {:error, "git arg #{inspect(arg)} modifies refs; git_read lists branches only"}
    else
      :ok
    end
  end

  defp classify_branch_arg(arg) do
    {:error,
     "git arg #{inspect(arg)} would create or retarget a branch; git_read lists branches " <>
       "only. Pass a flag value in the = form, e.g. --contains=HEAD"}
  end

  defp branch_mutating_flag?("--" <> rest = arg) when byte_size(rest) > 0 do
    token = arg |> String.split("=", parts: 2) |> hd()
    Enum.any?(@branch_mutating_flags, &String.starts_with?(&1, token))
  end

  defp branch_mutating_flag?(arg), do: arg in @branch_mutating_short

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
