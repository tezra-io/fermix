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

  @not_running_exit 3

  @spec run([String.t()]) :: non_neg_integer()
  def run(_argv) do
    case Client.status() do
      {:ok, %{"status" => "ok"} = reply} -> print_ok(reply)
      {:ok, other} -> print_unexpected(other)
      {:error, :not_running} -> print_not_running()
      {:error, reason} -> print_error(reason)
    end
  end

  defp print_ok(%{"version" => version, "uptime_ms" => uptime_ms} = reply) do
    pid = Map.get(reply, "pid", "?")
    IO.puts("fermix: running (pid #{pid}, version #{version}, up #{format_uptime(uptime_ms)})")
    0
  end

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
