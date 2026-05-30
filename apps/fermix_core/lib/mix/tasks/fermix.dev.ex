defmodule Mix.Tasks.Fermix.Dev do
  @moduledoc """
  Run the full Fermix daemon from source — dev equivalent of `fermix run`.

  Enables the daemon control socket, the Realtime voice socket, and the
  Phoenix endpoint server, then starts `:fermix_core`, `:fermix_channels`,
  and `:fermix_web` in one BEAM node. A single Ctrl-C tears the whole
  stack down.

  Channels and the Realtime voice subsystem are gated on config: if
  Telegram has no bot token the poller does not start; if Realtime is
  disabled or has no OpenAI key the socket does not start. Neither
  failure aborts boot — both are reported in the readiness banner.

  Flags:
    --no-channels   Skip the channels app (Telegram, WhatsApp, Slack, Discord, Signal)
    --no-web        Skip the Phoenix endpoint and webhook routes
    --no-realtime   Skip the local Realtime voice socket
  """

  use Mix.Task

  alias FermixCore.Realtime.Config, as: RealtimeConfig
  alias FermixCore.Realtime.LocalVoiceSocket
  alias FermixCore.Setup.ConfigStore

  @shortdoc "Run the full Fermix daemon from source"

  @switches [channels: :boolean, web: :boolean, realtime: :boolean]
  @default_port 4030

  @impl true
  def run(argv) do
    Mix.Task.run("loadpaths")
    Mix.Task.run("app.config")

    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    channels? = Keyword.get(opts, :channels, true)
    web? = Keyword.get(opts, :web, true)
    realtime? = Keyword.get(opts, :realtime, true)

    enable_daemon_socket()
    if realtime?, do: enable_realtime_socket()
    if web?, do: enable_endpoint_server()

    if web?, do: preflight_port!(phoenix_port())

    start!(:fermix_core)
    if channels?, do: start!(:fermix_channels)
    if web?, do: start!(:fermix_web)

    print_ready(channels?, web?, realtime?)
    block_until_shutdown()
  end

  defp enable_daemon_socket do
    Application.put_env(:fermix_core, :daemon_socket_enabled, true)
  end

  defp enable_realtime_socket do
    Application.put_env(:fermix_core, :realtime_socket_enabled, true)
  end

  defp enable_endpoint_server do
    endpoint = Application.get_env(:fermix_web, FermixWebWeb.Endpoint, [])
    Application.put_env(:fermix_web, FermixWebWeb.Endpoint, Keyword.put(endpoint, :server, true))
  end

  defp start!(app) do
    case Application.ensure_all_started(app) do
      {:ok, _apps} ->
        :ok

      {:error, reason} ->
        Mix.raise("failed to start #{app}: #{inspect(reason)}")
    end
  end

  defp phoenix_port do
    :fermix_web
    |> Application.get_env(FermixWebWeb.Endpoint, [])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port, @default_port)
  end

  defp preflight_port!(port) do
    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, :eaddrinuse} ->
        Mix.raise("""
        Port #{port} is already in use.

        Another Fermix daemon (or unrelated process) is already bound to
        127.0.0.1:#{port}. Stop it first, or run `mix fermix.dev --no-web`
        to start without the Phoenix endpoint.
        """)

      {:error, reason} ->
        Mix.raise("port #{port} preflight failed: #{inspect(reason)}")
    end
  end

  defp print_ready(channels?, web?, realtime?) do
    Mix.shell().info("")
    Mix.shell().info("Fermix dev daemon online")
    Mix.shell().info("  Daemon socket:    #{daemon_socket_path()}")

    if web? do
      Mix.shell().info("  Phoenix endpoint: http://127.0.0.1:#{phoenix_port()}")
    else
      Mix.shell().info("  Phoenix endpoint: (skipped — --no-web)")
    end

    Mix.shell().info("  Realtime socket:  #{realtime_status(realtime?)}")
    Mix.shell().info("  Channels:         #{channels_status(channels?)}")
    Mix.shell().info("")
    Mix.shell().info("Ctrl-C twice to stop.")
  end

  defp daemon_socket_path do
    Path.join(ConfigStore.fermix_home(), "daemon.sock")
  end

  defp realtime_status(false), do: "(skipped — --no-realtime)"

  defp realtime_status(true) do
    cond do
      Process.whereis(LocalVoiceSocket) != nil ->
        RealtimeConfig.socket_path()

      not RealtimeConfig.enabled?() ->
        "(disabled in config.toml — fermix_core.realtime.enabled=false)"

      true ->
        "(not started — check OPENAI_API_KEY and realtime config)"
    end
  end

  defp channels_status(false), do: "(skipped — --no-channels)"

  defp channels_status(true) do
    enabled =
      [:telegram, :discord, :signal, :slack, :whatsapp]
      |> Enum.filter(fn ch ->
        :fermix_channels
        |> Application.get_env(ch, [])
        |> Keyword.get(:enabled, false)
      end)

    case enabled do
      [] -> "(none enabled in config.toml)"
      list -> Enum.map_join(list, ", ", &Atom.to_string/1)
    end
  end

  defp block_until_shutdown do
    Process.flag(:trap_exit, true)

    receive do
      :shutdown -> :ok
      {:EXIT, _pid, _reason} -> block_until_shutdown()
    end
  end
end
