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
        print_realtime_status("online", realtime_map(health), json?)

      {:ok, other} ->
        unexpected(other)

      {:error, :not_running} ->
        health = Health.report() |> Jason.encode!() |> Jason.decode!()
        print_realtime_status("offline", realtime_map(health), json?)

      {:error, reason} ->
        error(reason)
    end
  end

  # Realtime authenticates with the plain `openai` provider key, which a Codex
  # subscription/OAuth login does not provide. Surface its presence so an
  # enabled-but-keyless companion is diagnosable without waiting for a call to
  # fail. Both the human and --json outputs carry it.
  defp realtime_map(health) do
    realtime = Map.get(health, "realtime", %{})
    Map.put(realtime, "openai_api_key_present?", openai_key_present?(realtime))
  end

  defp openai_key_present?(realtime) do
    Map.get(realtime, "enabled", false) and
      match?({:ok, _}, FermixCore.Config.provider_api_key(:openai))
  end

  defp realtime_key_label(realtime) do
    cond do
      not Map.get(realtime, "enabled", false) -> "n/a (disabled)"
      Map.get(realtime, "openai_api_key_present?", false) -> "present"
      true -> "MISSING — Realtime needs an OpenAI sk- key (Codex OAuth won't authorize it)"
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
    IO.puts("realtime key: #{realtime_key_label(realtime)}")
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
