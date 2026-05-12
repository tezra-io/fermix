defmodule Mix.Tasks.Fermix.Dev.Realtime do
  @moduledoc """
  Run the local Realtime daemon path from source.

  This is a development-only wrapper around the same supervision gates that the
  Burrito `fermix run` command enables. It starts `fermix_core` with the daemon
  control socket and Realtime voice socket enabled, without requiring a packaged
  binary install.
  """

  use Mix.Task

  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.LocalVoiceSocket

  @shortdoc "Run the local Realtime daemon from source"

  @switches [web: :boolean, channels: :boolean]

  @impl true
  def run(argv) do
    Mix.Task.run("loadpaths")
    Mix.Task.run("app.config")

    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    enable_daemon_paths()
    maybe_enable_endpoint(Keyword.get(opts, :web, false))

    start!(:fermix_core)
    maybe_start(:fermix_channels, Keyword.get(opts, :channels, false))
    maybe_start(:fermix_web, Keyword.get(opts, :web, false))

    assert_realtime_started!()
    print_ready()
    block_until_shutdown()
  end

  defp enable_daemon_paths do
    Application.put_env(:fermix_core, :daemon_socket_enabled, true)
    Application.put_env(:fermix_core, :realtime_socket_enabled, true)
  end

  defp maybe_enable_endpoint(false), do: :ok

  defp maybe_enable_endpoint(true) do
    endpoint = Application.get_env(:fermix_web, FermixWebWeb.Endpoint, [])
    Application.put_env(:fermix_web, FermixWebWeb.Endpoint, Keyword.put(endpoint, :server, true))
  end

  defp start!(app) do
    case Application.ensure_all_started(app) do
      {:ok, _apps} -> :ok
      {:error, reason} -> Mix.raise("failed to start #{app}: #{inspect(reason)}")
    end
  end

  defp maybe_start(_app, false), do: :ok
  defp maybe_start(app, true), do: start!(app)

  defp assert_realtime_started! do
    if Process.whereis(LocalVoiceSocket) == nil do
      Mix.raise("""
      Realtime socket did not start.

      Required for this dev task:
        FERMIX_REALTIME_ENABLED=true
        FERMIX_REALTIME_MODEL=gpt-realtime-2
        OPENAI_API_KEY or a persisted OpenAI API key in FERMIX_HOME/config.toml
      """)
    end
  end

  defp print_ready do
    socket_path = Config.socket_path()

    Mix.shell().info("Fermix dev realtime daemon online")
    Mix.shell().info("Realtime socket: #{socket_path}")
    Mix.shell().info("")
    Mix.shell().info("Launch the companion with:")
    Mix.shell().info("  cd clients/macos/FermixPet")

    Mix.shell().info(
      "  FERMIX_HOME=#{System.get_env("FERMIX_HOME") || "~/.fermix"} swift run FermixPet"
    )
  end

  defp block_until_shutdown do
    Process.flag(:trap_exit, true)

    receive do
      :shutdown -> :ok
      {:EXIT, _pid, _reason} -> block_until_shutdown()
    end
  end
end
