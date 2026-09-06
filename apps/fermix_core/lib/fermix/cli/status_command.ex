defmodule Fermix.CLI.StatusCommand do
  @moduledoc """
  `fermix status` — print the running daemon's status from the management
  socket.

  M34 §2 defines no v1 `status` method, so the plain line is projected from two
  calls: `hello` carries identity and the negotiated protocol range, and
  `overview.get` carries the daemon's own status and uptime. `--json` and
  `--full` render `overview.get` alone.

  Returns `0` when the daemon answers, `1` when it answers but cannot report,
  and `3` when nothing is listening (the conventional "service not running"
  exit so monitoring scripts can branch on it).

  `overview.get` is the daemon's public projection: it carries no filesystem
  path and no raw failure term, so `--full` reports neither. Both remain
  available through `fermix doctor` and `fermix logs`.
  """

  alias Fermix.CLI.Daemon.Client
  alias Fermix.CLI.VersionSkew

  @not_running_exit 3

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) when is_list(argv) do
    case OptionParser.parse(argv, strict: [json: :boolean, full: :boolean]) do
      {opts, [], []} -> run_status(opts)
      {_opts, _args, invalid} -> print_invalid(invalid)
    end
  end

  defp run_status(opts) do
    cond do
      Keyword.get(opts, :json) -> print_overview(:json)
      Keyword.get(opts, :full) -> print_overview(:full)
      true -> print_daemon_status()
    end
  end

  defp print_daemon_status do
    with {:ok, hello} <- Client.request_v1("hello"),
         {:ok, overview} <- Client.request_v1("overview.get") do
      print_running(hello, overview)
    else
      {:error, reason} -> print_failure(reason)
    end
  end

  defp print_overview(mode) when mode in [:json, :full] do
    case Client.request_v1("overview.get") do
      {:ok, overview} -> print_overview(mode, overview)
      {:error, reason} -> print_failure(reason)
    end
  end

  defp print_overview(:json, overview) do
    IO.puts(Jason.encode!(overview))
    0
  end

  defp print_overview(:full, overview) do
    daemon = Map.get(overview, "daemon", %{})
    IO.puts("fermix: #{Map.get(daemon, "status", "unknown")}")
    IO.puts("readiness: #{get_in(overview, ["readiness", "status"]) || "unknown"}")
    IO.puts("main agent: #{main_health(overview)}")
    IO.puts("main activity: #{main_activity(overview)}")
    IO.puts("workers: #{Map.get(overview["agents"] || %{}, "skill_workers", 0)}")
    IO.puts("jobs: #{format_jobs(Map.get(overview, "jobs", %{}))}")
    IO.puts("capabilities: #{format_capabilities(Map.get(overview, "capabilities", %{}))}")
    0
  end

  defp print_running(hello, overview) do
    daemon = Map.get(overview, "daemon", %{})
    version = get_in(hello, ["engine", "product_version"])
    pid = get_in(hello, ["engine", "pid"]) || "?"
    protocol = get_in(hello, ["protocol", "current_version"])

    IO.puts(
      "fermix: running (pid #{pid}, version #{version}, " <>
        "up #{format_uptime(Map.get(daemon, "uptime_ms"))}, protocol v#{protocol})"
    )

    print_skew_warning(VersionSkew.note(version))
    0
  end

  defp print_skew_warning(nil), do: :ok
  defp print_skew_warning(note), do: IO.puts("warning: #{note}")

  defp print_not_running do
    IO.puts(:stderr, "fermix: not running")
    @not_running_exit
  end

  defp print_failure(:not_running), do: print_not_running()

  defp print_failure(reason) do
    IO.puts(:stderr, "fermix status: #{Client.describe_error(reason)}")
    1
  end

  defp print_invalid(invalid) do
    IO.puts(:stderr, "fermix status: invalid options #{inspect(invalid)}")
    2
  end

  # The projection publishes the unavailability but not the raw registry term
  # behind it, which `fermix doctor` and the daemon log still carry.
  defp format_jobs(jobs) do
    case Map.get(jobs, "status") do
      "unavailable" ->
        "unavailable (see `fermix doctor`)"

      _status ->
        "scheduled #{Map.get(jobs, "scheduled", 0)}, running #{Map.get(jobs, "running", 0)}, " <>
          "paused #{Map.get(jobs, "paused", 0)}, failed recent #{Map.get(jobs, "failed_recent", 0)}"
    end
  end

  defp format_capabilities(capabilities) do
    "builtin #{Map.get(capabilities, "builtin", 0)}, skill #{Map.get(capabilities, "skill", 0)}, " <>
      "mcp #{Map.get(capabilities, "mcp", 0)}"
  end

  defp main_health(overview) do
    get_in(overview, ["agents", "main", "health"]) ||
      get_in(overview, ["agents", "main", "status"]) ||
      "unknown"
  end

  defp main_activity(overview) do
    get_in(overview, ["agents", "main", "activity"]) ||
      get_in(overview, ["agents", "main", "status"]) ||
      "unknown"
  end

  defp format_uptime(ms) when is_integer(ms) and ms >= 0 do
    seconds = div(ms, 1_000)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3_600 -> "#{div(seconds, 60)}m#{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3_600)}h#{div(rem(seconds, 3_600), 60)}m"
    end
  end

  defp format_uptime(other), do: inspect(other)
end
