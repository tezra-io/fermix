defmodule FermixCore.Health do
  @moduledoc """
  Aggregates the runtime-facing health report for setup, providers, channels,
  config paths, and memory backends.
  """

  alias FermixCore.Config
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Store
  alias FermixCore.Realtime.Config, as: RealtimeConfig
  alias FermixCore.Realtime.LocalVoiceSocket
  alias FermixCore.Realtime.SessionSupervisor
  alias FermixCore.Setup.BootReport
  alias FermixCore.Setup.ConfigStore

  require Logger

  @channels [
    %{
      key: :telegram,
      name: "telegram",
      default_enabled: true,
      runtime_modes: %{polling: FermixChannels.Channels.Telegram.Poller}
    },
    %{
      key: :whatsapp,
      name: "whatsapp",
      default_enabled: false,
      runtime_modes: %{}
    },
    %{
      key: :discord,
      name: "discord",
      default_enabled: false,
      runtime_modes: %{gateway: FermixChannels.Channels.Discord.Gateway}
    },
    %{
      key: :slack,
      name: "slack",
      default_enabled: false,
      runtime_modes: %{}
    },
    %{
      key: :signal,
      name: "signal",
      default_enabled: false,
      runtime_modes: %{subprocess: FermixChannels.Channels.Signal.Listener}
    }
  ]

  @spec report(keyword()) :: map()
  def report(opts \\ []) do
    boot_report = Keyword.get_lazy(opts, :boot_report, &BootReport.current/0)
    process_resolver = Keyword.get(opts, :process_resolver, &Process.whereis/1)
    timestamp = Keyword.get(opts, :timestamp, DateTime.utc_now())

    channels = channel_statuses(boot_report.failures, process_resolver)
    memory = memory_status(process_resolver)
    realtime = realtime_status(boot_report.failures, process_resolver)

    %{
      status: overall_status(boot_report.status, channels, memory, realtime),
      app: "fermix",
      version: "0.1.0",
      timestamp: timestamp,
      failures: Map.get(boot_report, :failures, []),
      config_path: boot_report.config_path,
      restart_required?: Map.get(boot_report, :restart_required?, false),
      config: %{
        home: ConfigStore.fermix_home(),
        path: boot_report.config_path,
        workspace: ConfigStore.workspace_paths()
      },
      providers: provider_statuses(boot_report.failures),
      channels: channels,
      memory: memory,
      realtime: realtime
    }
  end

  defp provider_statuses(failures) do
    openai_config =
      case Config.provider(:openai) do
        {:ok, config} -> config
        _ -> []
      end

    [
      %{
        name: "openai",
        status: failure_status(failures, "provider:openai") || :ready,
        auth_mode: Keyword.get(openai_config, :auth_mode, :api_key)
      }
    ]
  end

  defp channel_statuses(failures, process_resolver) do
    Enum.map(@channels, fn channel ->
      config =
        case Config.channel(channel.key) do
          {:ok, value} -> value
          _ -> []
        end

      enabled = Keyword.get(config, :enabled, channel.default_enabled) == true
      mode = Keyword.get(config, :mode)
      process_alive = process_alive(channel.runtime_modes, mode, enabled, process_resolver)

      status =
        cond do
          not enabled ->
            :disabled

          failure = failure_status(failures, "channel:#{channel.name}") ->
            failure

          process_alive == false ->
            :degraded

          true ->
            :ready
        end

      %{
        name: channel.name,
        status: status,
        enabled: enabled,
        mode: mode,
        process_alive: process_alive
      }
    end)
  end

  defp process_alive(_runtime_modes, _mode, false, _resolver), do: nil

  defp process_alive(runtime_modes, mode, true, resolver) do
    case Map.get(runtime_modes, mode) do
      nil -> nil
      process_name -> resolver.(process_name) != nil
    end
  end

  defp memory_status(process_resolver) do
    %{
      conversation_store: process_status(process_resolver.(ConversationStore)),
      store: process_status(process_resolver.(Store))
    }
  end

  defp realtime_status(failures, process_resolver) do
    config = RealtimeConfig.current()

    if config.enabled? do
      realtime_enabled_status(config, failures, process_resolver)
    else
      %{
        enabled: false,
        status: :disabled,
        provider: nil,
        model: nil,
        socket_path: nil,
        socket_alive: nil,
        active_sessions: 0,
        active_clients: 0,
        companion_connected?: false
      }
    end
  end

  defp realtime_enabled_status(config, failures, process_resolver) do
    socket_alive = process_resolver.(LocalVoiceSocket) != nil
    session_alive = process_resolver.(SessionSupervisor) != nil
    counts = realtime_counts(socket_alive, session_alive)

    status =
      cond do
        failure_status(failures, "realtime:openai") -> :setup_required
        not socket_alive or not session_alive -> :degraded
        true -> :ready
      end

    %{
      enabled: true,
      status: status,
      provider: config.provider,
      model: config.model,
      socket_path: RealtimeConfig.socket_path(),
      socket_alive: socket_alive,
      active_sessions: counts.active_sessions,
      active_clients: counts.active_clients,
      companion_connected?: counts.active_clients > 0
    }
  end

  defp realtime_counts(true, true) do
    %{
      active_sessions: SessionSupervisor.active_sessions(),
      active_clients: realtime_client_count()
    }
  end

  defp realtime_counts(_socket_alive, _session_alive) do
    %{active_sessions: 0, active_clients: 0}
  end

  defp realtime_client_count do
    case LocalVoiceSocket.active_clients() do
      {:ok, count} ->
        count

      {:error, reason} ->
        Logger.warning(
          "Realtime active_clients probe failed: #{inspect(reason)}; reporting 0 for health"
        )

        0
    end
  end

  defp process_status(nil), do: :degraded
  defp process_status(_pid), do: :ready

  defp overall_status(:setup_required, _channels, _memory, _realtime), do: :setup_required
  defp overall_status(:degraded, _channels, _memory, _realtime), do: :degraded

  defp overall_status(_status, channels, memory, realtime) do
    cond do
      Enum.any?(channels, &(&1.status == :degraded)) ->
        :degraded

      Enum.any?(Map.values(memory), &(&1 == :degraded)) ->
        :degraded

      realtime.status == :degraded ->
        :degraded

      true ->
        :ready
    end
  end

  defp failure_status(failures, component) do
    if Enum.any?(failures, &(&1.component == component)) do
      :setup_required
    end
  end
end
