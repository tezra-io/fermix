defmodule Fermix.CLI.LogsCommand do
  @moduledoc """
  `fermix logs [-f|--follow] [-n LINES]` — show the daemon's log file.

  Shells out to `tail` so output streams in real time when `-f` is
  passed. We resolve the log path the same way `FermixCore.Application`
  does (`FERMIX_HOME/logs/fermix.log`) so a fresh install with no
  `~/.fermix` yet exits with a clear "no log file" message instead of
  hanging on a missing path.
  """

  alias FermixCore.Setup.ConfigStore

  @switches [follow: :boolean, lines: :integer]
  @aliases [f: :follow, n: :lines]
  @default_lines 100

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) do
    case OptionParser.parse(argv, strict: @switches, aliases: @aliases) do
      {opts, _, []} -> dispatch(opts)
      {_, _, invalid} -> abort("invalid options: #{inspect(invalid)}")
    end
  end

  defp dispatch(opts) do
    log_path = log_path()

    cond do
      not File.exists?(log_path) ->
        abort("no log file at #{log_path}. Has the daemon ever run?")

      Keyword.get(opts, :follow, false) ->
        run_tail(["-n", to_string(line_count(opts)), "-f", log_path])

      true ->
        run_tail(["-n", to_string(line_count(opts)), log_path])
    end
  end

  defp line_count(opts), do: Keyword.get(opts, :lines, @default_lines)

  defp run_tail(args) do
    case System.find_executable("tail") do
      nil ->
        abort("`tail` not found on PATH; cannot stream logs.")

      tail ->
        port = Port.open({:spawn_executable, tail}, [:exit_status, :binary, args: args])
        forward_port(port)
    end
  end

  defp forward_port(port) do
    receive do
      {^port, {:data, chunk}} ->
        IO.write(chunk)
        forward_port(port)

      {^port, {:exit_status, status}} ->
        status
    end
  end

  defp log_path do
    log_config = Application.get_env(:fermix_core, :log, [])
    Keyword.get(log_config, :file, default_log_file())
  end

  defp default_log_file do
    Path.join(ConfigStore.workspace_paths().logs, "fermix.log")
  end

  defp abort(message) do
    IO.puts(:stderr, "fermix logs: #{message}")
    1
  end
end
