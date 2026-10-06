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

  Four optional entry keys:
  - `trust: :local_operator` — the transport is a same-user local surface the
    human owner is sitting at (CLI, daemon). `Gateway.Authorizer` resolves it to
    an operator authorization before any sender lookup, and the ingress gates
    below exempt it: such a channel has no inbox and therefore no allow-list.
  - `commands?: false` — the gateway skips the slash-command pipeline for the
    channel entirely; message content is always model input. Absent means `true`.
  - `platform: :macos` — the transport only exists on a Mac (iMessage reads the
    Messages of the Mac it runs on). Elsewhere it is never started and never
    reported as missing an owner. Absent means every platform. The host
    platform is injected (`macos?:`) and read from the OS in one place only.
  - `helper: Module` — the transport runs a helper that must be on disk
    (`Module.installed?/0`). Without it the channel is not started and
    `missing_helpers/1` names it, so a pin that moved with a release never
    fails the boot. Absent means nothing is required.
  """

  alias FermixCore.Config

  @type trust :: :local_operator
  @type ingress_auth :: :paired_device
  @type platform :: :macos

  @type channel :: %{
          :name => String.t(),
          :config_key => atom() | nil,
          :adapter => module() | nil,
          :remote? => boolean(),
          :transport => :polling | :gateway | :subprocess | :webhook | :loopback | :listener,
          :child => module() | nil,
          optional(:trust) => trust(),
          optional(:ingress_auth) => ingress_auth(),
          optional(:commands?) => boolean(),
          optional(:platform) => platform(),
          optional(:helper) => module()
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
    # MILESTONE_54: the signed Fermix Messages helper holds the Mac's grants;
    # the supervisor owns its process (`IMessage.Port`) and the listener that
    # ingests what it admits. Only a Mac has Messages to read.
    %{
      name: "imessage",
      config_key: :imessage,
      adapter: FermixChannels.Channels.IMessage,
      remote?: true,
      transport: :subprocess,
      child: FermixChannels.Channels.IMessage.Supervisor,
      platform: :macos,
      helper: FermixCore.IMessage.HelperInstaller
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
    # The Live voice engine's delegation surface (M41 §7). `remote?: true` like
    # ACP so a call's browser stays warm across delegations and a one-shot reap
    # never pulls it mid-call. Trust comes from the transport — the daemon's own
    # Live session, reached in process — not from a sender id, so there is no
    # inbox and no allow-list; the slash-command pipeline is off, so spoken text
    # can never reach daemon administration. No `child`: the session calls
    # `Voice.Bridge` directly, and `Voice.Supervisor` (which owns the routing
    # Registry) is started unconditionally by `FermixChannels.Application`.
    %{
      name: "voice",
      config_key: nil,
      adapter: FermixChannels.Channels.Voice,
      remote?: true,
      trust: :local_operator,
      commands?: false,
      transport: :loopback,
      child: nil
    },
    # The Mac app's chat (`companion.sock`). Like ACP, `remote?: true` keeps a
    # browser warm across turns of a persistent conversation, and trust comes
    # from the transport, a 0600 socket under FERMIX_HOME, so there is no inbox
    # and no allow-list. Slash commands stay on: an approval card's approve and
    # deny routes are commands. No `child` and no config key: the socket runs
    # whenever the daemon does, under `Companion.Supervisor`, which
    # `FermixChannels.Application` starts unconditionally.
    %{
      name: "companion",
      config_key: nil,
      adapter: FermixChannels.Channels.Companion,
      remote?: true,
      trust: :local_operator,
      transport: :loopback,
      child: nil
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

  @doc """
  Config keys of the remote channels (for ingress-authorization checks).

  A remote entry with no config key (the voice channel: remote lifecycle, local
  operator trust, no inbox) has no ingress list to check, so it contributes no
  key rather than a `nil` every caller would have to filter out itself.
  """
  @spec remote_channels() :: [atom()]
  def remote_channels do
    channels()
    |> Enum.filter(& &1.remote?)
    |> Enum.map(& &1.config_key)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Supervised transport children to start, gated by readiness, the host
  platform, the channel's `enabled` flag, its configured mode matching its
  transport, and ingress authorization. Replaces the hardcoded per-mode startup
  branches. `macos?:` injects the host platform (tests); absent, it is read
  from the OS.
  """
  @spec transport_children(map(), keyword()) :: [{module(), keyword()}]
  def transport_children(readiness, opts \\ [])

  def transport_children(%{status: :ready}, opts) when is_list(opts) do
    host = [macos?: host_macos?(opts)]

    channels()
    |> Enum.filter(&(platform_ok?(&1, host) and startable?(&1)))
    |> Enum.map(fn %{child: child} -> {child, []} end)
  end

  def transport_children(_not_ready, opts) when is_list(opts), do: []

  @doc """
  Remote channels that are enabled but missing ingress authorization (for
  refusal logging). A channel this platform cannot run is never listed.
  """
  @spec missing_ingress_authorizations(keyword()) :: [atom()]
  def missing_ingress_authorizations(opts \\ []) when is_list(opts) do
    host = [macos?: host_macos?(opts)]

    channels()
    |> Enum.filter(&(&1.remote? and needs_ingress?(&1) and platform_ok?(&1, host)))
    |> Enum.filter(fn %{config_key: key} ->
      config = channel_config(key)
      enabled?(config) and not ingress_authorized?(key)
    end)
    |> Enum.map(& &1.config_key)
  end

  @doc """
  Enabled channels this platform can run whose helper is not on disk (for
  refusal logging); `transport_children/2` leaves them out.
  """
  @spec missing_helpers(keyword()) :: [atom()]
  def missing_helpers(opts \\ []) when is_list(opts) do
    host = [macos?: host_macos?(opts)]

    channels()
    |> Enum.filter(&(Map.has_key?(&1, :helper) and platform_ok?(&1, host)))
    |> Enum.filter(fn %{config_key: key} = channel ->
      enabled?(channel_config(key)) and not helper_present?(channel)
    end)
    |> Enum.map(& &1.config_key)
  end

  @doc """
  Whether a registry entry can run on the host described by `opts`. The host
  must be injected (`macos?: boolean`); this function never reads the OS.
  """
  @spec platform_ok?(channel(), keyword()) :: boolean()
  def platform_ok?(channel, opts) when is_map(channel) and is_list(opts) do
    case Map.get(channel, :platform) do
      nil -> true
      :macos -> Keyword.fetch!(opts, :macos?) == true
    end
  end

  defp find(name), do: Enum.find(channels(), fn channel -> channel.name == name end)

  # The one place the host platform is read from the OS; every caller can
  # inject it instead.
  defp host_macos?(opts),
    do: Keyword.get_lazy(opts, :macos?, fn -> match?({:unix, :darwin}, :os.type()) end)

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
      (not needs_ingress?(channel) or ingress_authorized?(key)) and helper_present?(channel)
  end

  # A transport that runs a helper (MILESTONE_54 §14: Fermix Messages) starts
  # only once the helper is on disk; the readiness row and Doctor name the gap.
  defp helper_present?(channel) do
    case Map.get(channel, :helper) do
      nil -> true
      helper -> helper.installed?()
    end
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
