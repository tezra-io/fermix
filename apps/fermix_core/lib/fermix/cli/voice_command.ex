defmodule Fermix.CLI.VoiceCommand do
  @moduledoc """
  `fermix voice` — local Realtime voice companion controls.
  """

  alias Fermix.CLI.Daemon.Client
  alias FermixCore.Health
  alias FermixCore.Realtime.Config, as: RealtimeConfig

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
    config = RealtimeConfig.current()

    case Client.request("health") do
      {:ok, %{"status" => "ok", "health" => health}} ->
        print_realtime_status("online", realtime_map(health, config), config.provider, json?)

      {:ok, other} ->
        unexpected(other)

      {:error, :not_running} ->
        health = Health.report() |> Jason.encode!() |> Jason.decode!()
        print_realtime_status("offline", realtime_map(health, config), config.provider, json?)

      {:error, reason} ->
        error(reason)
    end
  end

  # Voice authenticates with the voice provider's plain API key, read through
  # `RealtimeConfig.api_key/1`: the `openai` provider key for OpenAI's engines,
  # which a Codex subscription/OAuth login does not provide, and the `xai`
  # provider key for Grok, which a SpaceXAI sign-in does not provide. Surface its
  # presence so an enabled-but-keyless companion is diagnosable without waiting
  # for a call to fail. Both the human and --json outputs carry it, named for
  # the provider whose key it is.
  defp realtime_map(health, config) do
    realtime = Map.get(health, "realtime", %{})

    Map.put(
      realtime,
      key_field(config.provider),
      Map.get(realtime, "enabled", false) and RealtimeConfig.api_key_present?(config)
    )
  end

  defp key_field(provider), do: "#{provider}_api_key_present?"

  defp realtime_key_label(realtime, provider) do
    cond do
      not Map.get(realtime, "enabled", false) -> "n/a (disabled)"
      Map.get(realtime, key_field(provider), false) -> "present"
      true -> missing_key_label(provider)
    end
  end

  defp missing_key_label("openai"),
    do: "MISSING — Realtime needs an OpenAI sk- key (Codex OAuth won't authorize it)"

  defp missing_key_label("xai"),
    do: "MISSING — Grok voice needs a SpaceXAI API key (a SpaceXAI sign-in won't authorize it)"

  defp print_realtime_status(daemon, realtime, _provider, true) do
    IO.puts(Jason.encode!(%{daemon: daemon, realtime: realtime}))
    0
  end

  defp print_realtime_status(daemon, realtime, provider, false) do
    IO.puts("fermix voice: #{Map.get(realtime, "status", "unknown")}")
    IO.puts("daemon: #{daemon}")
    IO.puts("enabled: #{Map.get(realtime, "enabled", false)}")
    IO.puts("provider: #{Map.get(realtime, "provider") || "none"}")
    IO.puts("engine: #{Map.get(realtime, "engine") || "none"}")
    IO.puts("model: #{Map.get(realtime, "model") || "none"}")
    IO.puts("realtime key: #{realtime_key_label(realtime, provider)}")
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
