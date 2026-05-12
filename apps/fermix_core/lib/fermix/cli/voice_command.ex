defmodule Fermix.CLI.VoiceCommand do
  @moduledoc """
  `fermix voice` — local Realtime voice companion controls.
  """

  alias Fermix.CLI.Daemon.Client
  alias FermixCore.Health

  @spec run([String.t()]) :: non_neg_integer()
  def run(["status" | argv]) do
    case OptionParser.parse(argv, strict: [json: :boolean]) do
      {opts, [], []} -> print_status(Keyword.get(opts, :json, false))
      {_opts, _args, invalid} -> invalid_options(invalid)
    end
  end

  def run(_argv) do
    IO.puts(:stderr, "fermix voice: usage: fermix voice status [--json]")
    2
  end

  defp print_status(json?) do
    case Client.request("health") do
      {:ok, %{"status" => "ok", "health" => health}} ->
        print_realtime_status("online", Map.get(health, "realtime", %{}), json?)

      {:ok, other} ->
        unexpected(other)

      {:error, :not_running} ->
        health = Health.report() |> Jason.encode!() |> Jason.decode!()
        print_realtime_status("offline", Map.get(health, "realtime", %{}), json?)

      {:error, reason} ->
        error(reason)
    end
  end

  defp print_realtime_status(daemon, realtime, true) do
    IO.puts(Jason.encode!(%{daemon: daemon, realtime: realtime}))
    0
  end

  defp print_realtime_status(daemon, realtime, false) do
    IO.puts("fermix voice: #{Map.get(realtime, "status", "unknown")}")
    IO.puts("daemon: #{daemon}")
    IO.puts("enabled: #{Map.get(realtime, "enabled", false)}")
    IO.puts("provider: #{Map.get(realtime, "provider") || "none"}")
    IO.puts("model: #{Map.get(realtime, "model") || "none"}")
    IO.puts("socket: #{Map.get(realtime, "socket_path") || "none"}")
    IO.puts("companion connected: #{Map.get(realtime, "companion_connected?", false)}")
    0
  end

  defp invalid_options(invalid) do
    IO.puts(:stderr, "fermix voice: invalid options #{inspect(invalid)}")
    2
  end

  defp unexpected(reply) do
    IO.puts(:stderr, "fermix voice: unexpected reply: #{inspect(reply)}")
    1
  end

  defp error(reason) do
    IO.puts(:stderr, "fermix voice: #{inspect(reason)}")
    1
  end
end
