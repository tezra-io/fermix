defmodule FermixCore.Health do
  @moduledoc """
  Aggregates the runtime-facing health report for setup, providers, channels,
  config paths, and memory backends.
  """

  alias FermixCore.BuildInfo
  alias FermixCore.Config
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Store
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.PrimaryConfig
  alias FermixCore.Providers.Selection
  alias FermixCore.Realtime.Config, as: RealtimeConfig
  alias FermixCore.Realtime.LocalVoiceSocket
  alias FermixCore.Realtime.SessionSupervisor
  alias FermixCore.Setup.BootReport
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState

  require Logger

  # `child:` names the supervised process whose liveness IS this channel's
  # runtime health, and `nil` means the channel runs no supervised child (it is
  # driven by an inbound webhook). Liveness is deliberately NOT keyed on the
  # configured `mode`: `ChannelRegistry.mode_ok?/3` already tolerates a stale
  # `mode = "webhook"` and starts the poller anyway, so keying on config made
  # health report a channel whose transport it had never looked at.
  #
  # ACP is probed through its `Endpoint`, never its `Supervisor`: an Endpoint
  # that cannot bind its socket returns `:ignore`, and the Supervisor starts
  # around it by design. Keying on the Supervisor would report a healthy ACP
  # with no bound socket.
  @channels [
    %{
      key: :telegram,
      name: "telegram",
      default_enabled: true,
      child: FermixChannels.Channels.Telegram.Poller,
      health_provider_key: :telegram_poll_health_provider
    },
    %{
      key: :whatsapp,
      name: "whatsapp",
      default_enabled: false,
      child: nil,
      health_provider_key: nil
    },
    %{
      key: :discord,
      name: "discord",
      default_enabled: false,
      child: FermixChannels.Channels.Discord.Gateway,
      health_provider_key: nil
    },
    %{
      key: :slack,
      name: "slack",
      default_enabled: false,
      child: nil,
      health_provider_key: nil
    },
    %{
      key: :signal,
      name: "signal",
      default_enabled: false,
      child: FermixChannels.Channels.Signal.Listener,
      health_provider_key: nil
    },
    %{
      key: :acp,
      name: "acp",
      default_enabled: true,
      child: FermixChannels.Channels.Acp.Endpoint,
      health_provider_key: nil
    }
  ]

  @spec report(keyword()) :: map()
  def report(opts \\ []) do
    boot_report = Keyword.get_lazy(opts, :boot_report, &BootReport.current/0)
    process_resolver = Keyword.get(opts, :process_resolver, &Process.whereis/1)
    transport_health = Keyword.get(opts, :transport_health, &default_transport_health/1)
    timestamp = Keyword.get(opts, :timestamp, DateTime.utc_now())
    # Restart truth comes from `RestartState` and from nowhere else. The boot
    # report is recomputed only when something saves, so reading it here would
    # leave an out-of-process `config.toml` write invisible to `/health` and to
    # `overview.get` until the operator happened to save something.
    restart = Keyword.get_lazy(opts, :restart, &RestartState.restart/0)

    channels = channel_statuses(boot_report.failures, process_resolver, transport_health)
    memory = memory_status(process_resolver)
    realtime = realtime_status(boot_report.failures, process_resolver)

    %{
      status: overall_status(boot_report.status, channels, memory, realtime),
      app: "fermix",
      version: BuildInfo.product_version(),
      timestamp: timestamp,
      failures: Map.get(boot_report, :failures, []),
      config_path: boot_report.config_path,
      restart_required?: Map.get(restart, :required, false) == true,
      restart_reasons: Enum.map(Map.get(restart, :reasons, []), & &1.section),
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

  # One entry per provider that matters: the configured primary (even when
  # its credentials are missing — that failure is the report's point) plus
  # every configured provider. Previously this hardcoded a single "openai"
  # entry regardless of the active provider (M12 §2.3-9).
  defp provider_statuses(failures) do
    primary = health_primary()

    Descriptor.ids()
    |> Enum.filter(fn provider -> provider == primary or Selection.configured?(provider) end)
    |> Enum.map(fn provider -> provider_status(provider, primary, failures) end)
  end

  defp provider_status(provider, primary, failures) do
    block =
      case Config.provider(provider) do
        {:ok, config} -> config
        _ -> []
      end

    descriptor = Descriptor.fetch!(provider)

    %{
      name: Atom.to_string(provider),
      status: failure_status(failures, "provider:#{provider}") || :ready,
      auth_mode: Keyword.get(block, :auth_mode, Descriptor.default_auth_mode(descriptor)),
      primary: provider == primary
    }
  end

  defp health_primary do
    case PrimaryConfig.primary() do
      {:ok, provider} -> provider
      {:error, :multiple_primary} -> nil
    end
  end

  defp channel_statuses(failures, process_resolver, transport_health) do
    Enum.map(@channels, fn channel ->
      config =
        case Config.channel(channel.key) do
          {:ok, value} -> value
          _ -> []
        end

      enabled = Keyword.get(config, :enabled, channel.default_enabled) == true
      channel_entry(channel, config, enabled, {failures, process_resolver, transport_health})
    end)
  end

  defp channel_entry(channel, config, enabled, resolvers) do
    {failures, process_resolver, transport_health} = resolvers
    process_alive = process_alive(channel.child, enabled, process_resolver)
    transport = transport(channel.health_provider_key, enabled, transport_health)

    status =
      cond do
        not enabled -> :disabled
        failure = failure_status(failures, "channel:#{channel.name}") -> failure
        process_alive == false -> :degraded
        match?(%{status: :degraded}, transport) -> :degraded
        true -> :ready
      end

    %{
      name: channel.name,
      status: status,
      enabled: enabled,
      # The persisted config value, reported as such. It no longer gates
      # liveness, but it is genuine information and consumers read it.
      mode: Keyword.get(config, :mode),
      process_alive: process_alive,
      transport: transport
    }
  end

  # `nil` means exactly one thing: disabled, or this channel runs no supervised
  # child. It never means "unknown, assume fine".
  defp process_alive(_child, false, _resolver), do: nil
  defp process_alive(nil, true, _resolver), do: nil
  defp process_alive(child, true, resolver) when is_atom(child), do: resolver.(child) != nil

  defp transport(_provider_key, false, _transport_health), do: nil
  defp transport(nil, true, _transport_health), do: nil

  defp transport(provider_key, true, transport_health) when is_atom(provider_key) do
    transport_health.(provider_key)
  end

  # The provider is registered by `FermixChannels.Application` iff that app runs;
  # core must not compile-depend on channels, so it is resolved at runtime. The
  # read is a pure `:persistent_term` lookup with no process involved — a
  # `GenServer.call` here would block behind a 50-second long poll.
  defp default_transport_health(provider_key) when is_atom(provider_key) do
    case Application.get_env(:fermix_core, provider_key) do
      nil -> nil
      provider when is_atom(provider) -> provider.poll_health()
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
