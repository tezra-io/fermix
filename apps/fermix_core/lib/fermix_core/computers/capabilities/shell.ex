defmodule FermixCore.Computers.Capabilities.Shell do
  @moduledoc """
  `shell` (M97 §6.4): commands and git on a computer of the home, held by
  that computer's kernel sandbox (Seatbelt on a Mac, Landlock on Linux) in
  its own mode, roots, blocked roots and environment allow list. Its `shell`
  switch gates it, at that computer. git is here, not under `files`: it runs
  programs a repository names (hooks, an fsmonitor, a diff driver).

  Each op runs the tool's own code (`perform/2`) under that computer's
  sandbox (`Computers.Capabilities.Local`):

  | op | tool | changes something |
  |---|---|---|
  | `shell.run` | `shell` | yes |
  | `git.read` | `git_read` | no |
  | `git.write` | `git_write` | yes |

  A command and a git write are never sent twice by the link: a lost answer
  is not known (`Computers.Outcome`). A folder outside the computer's roots
  is refused `outside_sandbox` before anything runs. Bounds are the tools'
  own: 1 MiB of a command's output, which rides the part above 256 KiB. The
  server decides with this computer's system whether a command waits for the
  owner after outside content (`Capabilities.AccessGate`).
  """

  @behaviour FermixCore.Computers.Capability

  alias FermixCore.Computers.Capabilities.Local
  alias FermixCore.Tools.GitRead
  alias FermixCore.Tools.GitWrite
  alias FermixCore.Tools.Shell, as: ShellTool

  @ops %{"shell.run" => ShellTool, "git.read" => GitRead, "git.write" => GitWrite}
  @effects ["shell.run", "git.write"]
  @result_bytes 256 * 1_024 + 16 * 1_024
  # A command's output is 1 MiB at most; its exit line and the note on what
  # the sandbox could not pass ride with it.
  @part_bytes 1_024 * 1_024 + 64 * 1_024
  @max_deadline_ms 900_000
  # Building a command's sandbox, and its allowed variables, takes this much
  # beyond the command's own timeout.
  @start_slack_ms 10_000
  @max_timeout_ms @max_deadline_ms - @start_slack_ms
  # `GitCommand`'s own ceiling for any git command, and the preflight's.
  @git_deadline_ms 130_000
  @word ~r/\A[A-Za-z0-9_.\/-]+\z/

  @impl true
  def id, do: :shell

  @impl true
  def offer, do: :shell

  @impl true
  def ops, do: @ops |> Map.keys() |> Enum.sort()

  @impl true
  def effect?(op) when is_map_key(@ops, op), do: op in @effects

  @impl true
  def long_lived?(op) when is_map_key(@ops, op), do: false

  @impl true
  def here?(context) when is_map(context), do: true

  @impl true
  def validate("shell.run", %{"timeout_ms" => ms}) when is_integer(ms) and ms > @max_timeout_ms,
    do: {:error, "A command on a computer runs for at most #{@max_timeout_ms} ms."}

  def validate(op, args) when is_map_key(@ops, op) and is_map(args), do: :ok

  @impl true
  def bounds(op) when is_map_key(@ops, op),
    do: %{result_bytes: @result_bytes, part_bytes: @part_bytes}

  @impl true
  def deadline_ms("shell.run", args) do
    case Map.get(args, "timeout_ms") do
      ms when is_integer(ms) and ms > 0 -> min(ms, @max_timeout_ms) + @start_slack_ms
      _default -> ShellTool.default_timeout_ms() + @start_slack_ms
    end
  end

  def deadline_ms(op, _args) when is_map_key(@ops, op), do: @git_deadline_ms

  @impl true
  def admit("shell.run", args, context),
    do: Local.admit_path(args["working_dir"], :folder, :shell, context)

  def admit("git.read", args, context),
    do: Local.admit_path(Map.get(args, "repo", File.cwd!()), :read, :git_read, context)

  def admit("git.write", args, context),
    do: Local.admit_path(Map.get(args, "repo", File.cwd!()), :folder, :git_write, context)

  @impl true
  def run(op, args, nil, context) when is_map_key(@ops, op),
    do: Local.ran(Map.fetch!(@ops, op).perform(args, Local.tool_context(context)))

  def run(_op, _args, _part, _context), do: {:failed, "This takes no file."}

  @impl true
  def target("shell.run", %{"command" => command}) when is_binary(command),
    do: command_words(command)

  def target("shell.run", _args), do: "a command"

  def target(op, args) when op in ["git.read", "git.write"] do
    ["git", args["command"], args["repo"]]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join(" ")
  end

  # A command's first words, never its content: the program and a plain
  # subcommand, stopping at anything that could carry a value (an assignment,
  # a quote, a flag's argument).
  defp command_words(command) do
    words =
      command
      |> String.split()
      |> Enum.take_while(&(Regex.match?(@word, &1) and not String.starts_with?(&1, "-")))
      |> Enum.take(2)

    if words == [], do: "a command", else: Enum.join(words, " ")
  end
end
