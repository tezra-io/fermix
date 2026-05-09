defmodule Fermix.CLI.HealthCommand do
  @moduledoc """
  `fermix health` — print daemon-evaluated readiness and health.
  """

  alias Fermix.CLI.Daemon.Client

  @not_running_exit 3

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) when is_list(argv) do
    case OptionParser.parse(argv, strict: [json: :boolean]) do
      {opts, [], []} -> request_health(Keyword.get(opts, :json, false))
      {_opts, _args, invalid} -> invalid_options(invalid)
    end
  end

  defp request_health(json?) do
    case Client.request("health") do
      {:ok, %{"status" => "ok", "health" => health}} -> print_health(health, json?)
      {:ok, other} -> unexpected(other)
      {:error, :not_running} -> not_running()
      {:error, reason} -> error(reason)
    end
  end

  defp print_health(health, true) do
    IO.puts(Jason.encode!(health))
    0
  end

  defp print_health(health, false) do
    IO.puts("fermix health: #{Map.get(health, "status", "unknown")}")
    IO.puts("providers: #{length(Map.get(health, "providers", []))}")
    IO.puts("channels: #{length(Map.get(health, "channels", []))}")
    IO.puts("failures: #{length(Map.get(health, "failures", []))}")
    0
  end

  defp invalid_options(invalid) do
    IO.puts(:stderr, "fermix health: invalid options #{inspect(invalid)}")
    2
  end

  defp unexpected(reply) do
    IO.puts(:stderr, "fermix health: unexpected reply: #{inspect(reply)}")
    1
  end

  defp not_running do
    IO.puts(:stderr, "fermix: not running")
    @not_running_exit
  end

  defp error(reason) do
    IO.puts(:stderr, "fermix health: #{inspect(reason)}")
    1
  end
end
