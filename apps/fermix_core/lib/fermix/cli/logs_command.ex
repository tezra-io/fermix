defmodule Fermix.CLI.LogsCommand do
  @moduledoc """
  `fermix logs [-f|--follow] [-n LINES]` — show the daemon's log.

  A standalone engine reads the file directly, shelling out to `tail` so output
  streams in real time when `-f` is passed. We resolve the log path the same way
  `FermixCore.Application` does (`FERMIX_HOME/logs/fermix.log`) so a fresh
  install with no `~/.fermix` yet exits with a clear "no log file" message
  instead of hanging on a missing path.

  An app-managed macOS engine asks the daemon instead (M34 §4): the daemon owns
  the rotation policy and the redactor, and the bundled CLI must never be the
  first reader of an unredacted line. `logs.query` is a bounded page, so the
  request ceiling is enforced here rather than quietly clamped, and `--follow`
  is refused — the management surface opens no streaming connection, and the
  application's Logs screen is what polls (M34 §5).
  """

  alias Fermix.CLI.Daemon.Client
  alias FermixCore.BuildInfo
  alias FermixCore.Management.Logs
  alias FermixCore.Setup.ConfigStore

  @switches [follow: :boolean, lines: :integer]
  @aliases [f: :follow, n: :lines]
  @default_lines 100

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv), do: run(argv, [])

  @doc false
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, deps) when is_list(argv) and is_list(deps) do
    case OptionParser.parse(argv, strict: @switches, aliases: @aliases) do
      {opts, _, []} -> dispatch(opts, deps)
      {_, _, invalid} -> abort("invalid options: #{inspect(invalid)}")
    end
  end

  defp dispatch(opts, deps) do
    build_info = Keyword.get(deps, :build_info, BuildInfo)

    if build_info.app_engine?() do
      query_daemon(opts, deps)
    else
      tail_file(opts)
    end
  end

  defp query_daemon(opts, deps) do
    follow? = Keyword.get(opts, :follow, false)
    lines = line_count(opts)

    cond do
      follow? -> abort(follow_message())
      lines < 1 or lines > Logs.max_limit() -> abort(limit_message(lines))
      true -> request_page(lines, deps)
    end
  end

  defp request_page(lines, deps) do
    client = Keyword.get(deps, :client, &Client.request_v1/3)
    params = %{"limit" => lines, "direction" => "backward"}

    case client.("logs.query", params, []) do
      {:ok, page} -> print_page(page)
      {:error, :not_running} -> abort(not_running_message())
      {:error, reason} -> abort(Client.describe_error(reason))
    end
  end

  defp print_page(page) do
    page
    |> Map.get("entries", [])
    |> Enum.each(&print_entry/1)

    if Map.get(page, "truncated", false) do
      IO.puts("(truncated: the page hit the #{Logs.max_result_bytes()}-byte result cap)")
    end

    0
  end

  defp print_entry(entry) when is_map(entry) do
    IO.puts(
      "#{Map.get(entry, "time", "?")} #{Map.get(entry, "level", "?")} " <>
        "#{Map.get(entry, "message", "")}"
    )
  end

  defp follow_message do
    "an app-managed engine serves bounded log pages and cannot follow. " <>
      "Open Fermix.app and use the Logs screen, which polls while it is visible."
  end

  defp limit_message(lines) do
    "-n must be between 1 and #{Logs.max_limit()} on an app-managed engine; got #{lines}."
  end

  defp not_running_message do
    "the daemon is not running, and an app-managed engine serves its log through it. " <>
      "Open Fermix.app and enable the background service."
  end

  defp tail_file(opts) do
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
