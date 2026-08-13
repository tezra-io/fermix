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

  Two optional entry keys:
  - `trust: :local_operator` — the transport is a same-user local surface the
    human owner is sitting at (CLI, daemon). `Gateway.Authorizer` resolves it to
    an operator authorization before any sender lookup, and the ingress gates
    below exempt it: such a channel has no inbox and therefore no allow-list.
  - `commands?: false` — the gateway skips the slash-command pipeline for the
    channel entirely; message content is always model input. Absent means `true`.
  """

  alias FermixCore.Config

  @type trust :: :local_operator
  @type ingress_auth :: :paired_device

  @type channel :: %{
          :name => String.t(),
          :config_key => atom() | nil,
          :adapter => module() | nil,
          :remote? => boolean(),
          :transport => :polling | :gateway | :subprocess | :webhook | :loopback | :listener,
          :child => module() | nil,
          optional(:trust) => trust(),
          optional(:ingress_auth) => ingress_auth(),
          optional(:commands?) => boolean()
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
    # The ACP agent surface (M29). `remote?: true` is deliberate: sessions are
    # persistent, so browsers stay warm across turns and detached continuation
    # delivery refuses loudly. Trust comes from the transport — a 0600 socket
    # under FERMIX_HOME — not from a sender id, and the slash-command pipeline is
    # off, so channel members cannot reach daemon administration.
    %{
      name: "acp",
      config_key: :acp,
      adapter: FermixChannels.Channels.Acp,
      remote?: true,
      trust: :local_operator,
      commands?: false,
      transport: :gateway,
      child: FermixChannels.Channels.Acp.Supervisor
    },
    %{
      name: "mobile",
      config_key: :mobile,
      adapter: FermixChannels.Channels.Mobile,
      remote?: true,
      ingress_auth: :paired_device,
      transport: :listener,
      child: FermixChannels.Mobile.Supervisor
    },
    %{
      name: "cli",
      config_key: nil,
      adapter: FermixChannels.CLI,
      remote?: false,
      transport: :loopback,
      child: nil,
      trust: :local_operator
    },
    %{
      name: "daemon",
      config_key: nil,
      adapter: nil,
      remote?: false,
      transport: :loopback,
      child: nil,
      trust: :local_operator
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

  @doc "Adapter module for a channel string; nil for the daemon channel or an unknown one."
  @spec adapter(String.t()) :: module() | nil
  def adapter(name) when is_binary(name) do
    case find(name) do
      %{adapter: adapter} -> adapter
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

  @doc """
  Trust the transport itself carries, independent of any sender identity.
  `:local_operator` for same-user local surfaces; `nil` for everything else
  (including unknown channels), which then authorize by sender id.
  """
  @spec trust(String.t()) :: trust() | nil
  def trust(name) when is_binary(name) do
    case find(name) do
      nil -> nil
      channel -> trust_of(channel)
    end
  end

  @doc "Connection-authenticated ingress required by a channel, if any."
  @spec ingress_auth(String.t()) :: ingress_auth() | nil
  def ingress_auth(name) when is_binary(name) do
    case find(name) do
      nil -> nil
      channel -> Map.get(channel, :ingress_auth)
    end
  end

  @doc """
  Whether the gateway runs the slash-command pipeline for this channel.
  Unknown channels and entries without the key answer `true` — opting out is
  always explicit.
  """
  @spec commands?(String.t()) :: boolean()
  def commands?(name) when is_binary(name) do
    case find(name) do
      nil -> true
      channel -> Map.get(channel, :commands?, true)
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
    |> Enum.filter(&(&1.remote? and needs_ingress?(&1)))
    |> Enum.filter(fn %{config_key: key} ->
      config = channel_config(key)
      enabled?(config) and not ingress_authorized?(key)
    end)
    |> Enum.map(& &1.config_key)
  end

  defp find(name), do: Enum.find(channels(), fn channel -> channel.name == name end)

  defp trust_of(channel) when is_map(channel), do: Map.get(channel, :trust)

  # A `:local_operator` transport has no inbox — nobody can address it but the
  # operator running it — so an ingress allow-list is not a thing it can have.
  defp needs_ingress?(channel) do
    trust_of(channel) != :local_operator and Map.get(channel, :ingress_auth) == nil
  end

  defp startable?(%{child: nil}), do: false

  defp startable?(%{config_key: key, transport: transport, child: child} = channel)
       when not is_nil(child) do
    config = channel_config(key)

    enabled?(config) and mode_ok?(key, config, transport) and
      (not needs_ingress?(channel) or ingress_authorized?(key))
  end

  defp channel_config(key), do: Application.get_env(:fermix_channels, key, [])

  defp enabled?(config), do: Keyword.get(config, :enabled, false) == true

  # Telegram is polling-only now, but older setup persisted `mode: :webhook`.
  # Keep that value from suppressing the only Telegram transport.
  defp mode_ok?(:telegram, config, :polling) do
    Keyword.get(config, :mode) in [nil, :polling, :webhook]
  end

  # Discord/Signal must match their transport. An unset mode is accepted as
  # "this transport" for hand-written minimal configs.
  defp mode_ok?(_key, config, transport), do: Keyword.get(config, :mode) in [nil, transport]

  defp ingress_authorized?(key), do: Config.channel_ingress_user_ids(key) != []
end
