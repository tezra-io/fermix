defmodule Fermix.CLI.StatusCommand do
  @moduledoc """
  `fermix status` — print the running daemon's status by talking to
  its control socket.

  Returns `0` when the daemon answers, `1` when the socket exists but
  the daemon is unhealthy, and `3` when nothing is listening (the
  conventional "service not running" exit so monitoring scripts can
  branch on it).
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
    case Client.status() do
      {:ok, %{"status" => "ok"} = reply} -> print_ok(reply)
      {:ok, other} -> print_unexpected(other)
      {:error, :not_running} -> print_not_running()
      {:error, reason} -> print_error(reason)
    end
  end

  defp print_overview(mode) when mode in [:json, :full] do
    case Client.request("overview") do
      {:ok, %{"status" => "ok", "overview" => overview}} -> print_overview(mode, overview)
      {:ok, %{"status" => "error", "reason" => reason}} -> print_error(reason)
      {:ok, other} -> print_unexpected(other)
      {:error, :not_running} -> print_not_running()
      {:error, reason} -> print_error(reason)
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
    IO.puts("paths: #{get_in(overview, ["paths", "home"]) || "unknown"}")
    0
  end

  defp print_ok(%{"version" => version, "uptime_ms" => uptime_ms} = reply) do
    pid = Map.get(reply, "pid", "?")
    IO.puts("fermix: running (pid #{pid}, version #{version}, up #{format_uptime(uptime_ms)})")
    print_skew_warning(VersionSkew.note(version))
    0
  end

  defp print_skew_warning(nil), do: :ok
  defp print_skew_warning(note), do: IO.puts("warning: #{note}")

  defp print_unexpected(reply) do
    IO.puts(:stderr, "fermix status: unexpected reply: #{inspect(reply)}")
    1
  end

  defp print_not_running do
    IO.puts(:stderr, "fermix: not running")
    @not_running_exit
  end

  defp print_error(reason) do
    IO.puts(:stderr, "fermix status: #{inspect(reason)}")
    1
  end

  defp print_invalid(invalid) do
    IO.puts(:stderr, "fermix status: invalid options #{inspect(invalid)}")
    2
  end

  defp format_jobs(jobs) do
    case Map.get(jobs, "status") do
      "unavailable" ->
        "unavailable (#{Map.get(jobs, "error", "unknown")})"

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
