defmodule FermixChannels.Gateway.ChannelRegistry do
  @moduledoc """
  Single source of truth for the channels Fermix knows about.

  Each entry maps a channel string to its `FermixCore.Config` key, adapter
  module, remoteness, transport, and the supervised child that runs that
  transport (if any). `Gateway.Source`, `Gateway.Authorizer`, and
  `FermixChannels.Application` read channel facts from here instead of hardcoding
  the channel list, so adding (or, in tests, faking) a channel is a
  registry/config change — not an edit to gateway source.

  Config-overridable like `Gateway.Commands.Registry`: set
  `config :fermix_channels, :channel_registry, [...]` to replace the default set
  (a test can register a fake channel without touching this module).

  Transport modes:
  - `:polling` (Telegram), `:gateway` (Discord), `:subprocess` (Signal) run a
    supervised child started by `FermixChannels.Application`.
  - `:webhook` (WhatsApp, Slack) is web-triggered — no child.
  - `:loopback` (CLI, daemon) is local/operator — no child, no config key.
  """

  alias FermixCore.Config

  @type channel :: %{
          name: String.t(),
          config_key: atom() | nil,
          adapter: module() | nil,
          remote?: boolean(),
          transport: :polling | :gateway | :subprocess | :webhook | :loopback,
          child: module() | nil
        }

  @default_channels [
    %{
      name: "telegram",
      config_key: :telegram,
      adapter: FermixChannels.Channels.Telegram,
      remote?: true,
      transport: :polling,
      child: FermixChannels.Channels.Telegram.Poller
    },
    %{
      name: "whatsapp",
      config_key: :whatsapp,
      adapter: FermixChannels.Channels.WhatsApp,
      remote?: true,
      transport: :webhook,
      child: nil
    },
    %{
      name: "slack",
      config_key: :slack,
      adapter: FermixChannels.Channels.Slack,
      remote?: true,
      transport: :webhook,
      child: nil
    },
    %{
      name: "discord",
      config_key: :discord,
      adapter: FermixChannels.Channels.Discord,
      remote?: true,
      transport: :gateway,
      child: FermixChannels.Channels.Discord.Gateway
    },
    %{
      name: "signal",
      config_key: :signal,
      adapter: FermixChannels.Channels.Signal,
      remote?: true,
      transport: :subprocess,
      child: FermixChannels.Channels.Signal.Listener
    },
    %{
      name: "cli",
      config_key: nil,
      adapter: FermixChannels.CLI,
      remote?: false,
      transport: :loopback,
      child: nil
    },
    %{
      name: "daemon",
      config_key: nil,
      adapter: nil,
      remote?: false,
      transport: :loopback,
      child: nil
    }
  ]

  @spec channels() :: [channel()]
  def channels, do: Application.get_env(:fermix_channels, :channel_registry, @default_channels)

  @doc "Config key for a channel string (used for owner/ingress lookups); nil for local/unknown."
  @spec channel_key(String.t()) :: atom() | nil
  def channel_key(name) when is_binary(name) do
    case find(name) do
      %{config_key: key} -> key
      nil -> nil
    end
  end

  @doc "Whether a channel is a local/operator loopback (cli, daemon)."
  @spec local?(String.t()) :: boolean()
  def local?(name) when is_binary(name) do
    case find(name) do
      %{remote?: false} -> true
      _channel -> false
    end
  end

  @doc "Config keys of the remote channels (for ingress-authorization checks)."
  @spec remote_channels() :: [atom()]
  def remote_channels do
    channels() |> Enum.filter(& &1.remote?) |> Enum.map(& &1.config_key)
  end

  @doc """
  Supervised transport children to start, gated by readiness, the channel's
  `enabled` flag, its configured mode matching its transport, and ingress
  authorization. Replaces the hardcoded per-mode startup branches.
  """
  @spec transport_children(map()) :: [{module(), keyword()}]
  def transport_children(%{status: :ready}) do
    channels()
    |> Enum.filter(&startable?/1)
    |> Enum.map(fn %{child: child} -> {child, []} end)
  end

  def transport_children(_not_ready), do: []

  @doc "Remote channels that are enabled but missing ingress authorization (for refusal logging)."
  @spec missing_ingress_authorizations() :: [atom()]
  def missing_ingress_authorizations do
    channels()
    |> Enum.filter(& &1.remote?)
    |> Enum.filter(fn %{config_key: key} ->
      config = channel_config(key)
      enabled?(config) and not ingress_authorized?(key)
    end)
    |> Enum.map(& &1.config_key)
  end

  defp find(name), do: Enum.find(channels(), fn channel -> channel.name == name end)

  defp startable?(%{child: nil}), do: false

  defp startable?(%{config_key: key, transport: transport, child: child})
       when not is_nil(child) do
    config = channel_config(key)
    enabled?(config) and mode_ok?(config, transport) and ingress_authorized?(key)
  end

  defp channel_config(key), do: Application.get_env(:fermix_channels, key, [])

  defp enabled?(config), do: Keyword.get(config, :enabled, false) == true

  # Telegram has no `:mode` in config (polling is implicit); Discord/Signal must
  # match their transport. An unset mode is accepted as "this transport".
  defp mode_ok?(config, transport), do: Keyword.get(config, :mode) in [nil, transport]

  defp ingress_authorized?(key), do: Config.channel_ingress_user_ids(key) != []
end
