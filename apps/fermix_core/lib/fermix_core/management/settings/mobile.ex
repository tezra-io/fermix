defmodule FermixCore.Management.Settings.Mobile do
  @moduledoc """
  The `channels.mobile` section: the phone channel's own switches (M51
  management pairing §6).

  A section of its own rather than a channels-inventory entry, because the
  inventory expresses credential rows and the phone channel has none: it needs
  two switches, a port, an address and an announcement. Every row is a projection of the one
  `[fermix_channels.mobile]` block. The two toggles are live: a write starts or
  stops the phone channel (M51 §5.5), or its reach from anywhere (M62), at once
  (`FermixCore.Management.Settings`). The port, the address and the
  announcement are boot-bound, because the channel reads them when it starts.

  Identity, protocol version and the relay remote reach uses are runtime facts
  rather than settings, so they are published on `mobile.status` and are not
  rows here.
  """

  alias FermixCore.Management.Settings.Row
  alias FermixCore.Management.Settings.Source

  @section %{id: "channels.mobile", pane: "channels", title: "Phone"}
  # The shipped defaults, read where the block does not set a key. They are the
  # listener's own; the channels app is not a compile dependency of this one.
  @default_port 4_031
  @default_bind "0.0.0.0"

  @doc "The one section this module owns."
  @spec sections() :: [%{id: String.t(), pane: String.t(), title: String.t()}]
  def sections, do: [@section]

  @doc "Whether this module owns the named section."
  @spec owns?(String.t()) :: boolean()
  def owns?(section) when is_binary(section), do: section == @section.id

  @doc "The rows of the owned section."
  @spec rows(String.t(), Source.snapshot()) :: [Row.t()]
  def rows("channels.mobile", snapshot) when is_map(snapshot) do
    block = Source.channel(snapshot, :mobile)
    restart = Row.restart?(:channels)
    switch_restart = Row.restart?([:channels, :mobile, :enabled])
    reach_restart = Row.restart?([:channels, :mobile, :iroh])

    [
      Row.new("mobile_enabled", :toggle, "Phone companion",
        footer: "Lets a paired phone chat with this Fermix.",
        value: Source.boolean(block, :enabled, false),
        restart: switch_restart
      ),
      Row.new("mobile_iroh", :toggle, "Reach from anywhere",
        # What the switch does, not whether it works today: the phone channel's
        # status says that (`remote`). One line, so the Phone sheet fits its
        # window; `info` says what off does, because Listen on and the
        # announcement do not confine this route.
        footer: "Uses Fermix's relays, which never see your messages.",
        info:
          "Lets your phone reach this Fermix from any network through Fermix's relays, " <>
            "besides your home network and Tailscale. The relays pass on encrypted traffic " <>
            "and never see your messages. Off keeps your phone to your home network and " <>
            "Tailscale.",
        value: Source.boolean(block, :iroh, true),
        restart: reach_restart
      ),
      # The network rows: rarely changed, so `advanced`. Neither the address
      # nor the announcement reaches the relay route, so neither footer may
      # promise a Tailscale-only phone.
      Row.new("mobile_port", :number, "Port",
        footer: "Change it only if something else uses it.",
        value: Source.number(block, :port, @default_port),
        min: 1_024,
        max: 65_535,
        step: 1,
        format: :integer,
        restart: restart,
        advanced: true
      ),
      Row.new("mobile_bind", :text, "Listen on",
        footer: "Every network, or only the one address you enter.",
        value: Source.string(block, :bind, @default_bind),
        restart: restart,
        advanced: true
      ),
      Row.new("mobile_advertise_mdns", :toggle, "Announce on the local network",
        footer: "Lets devices on this network find this Fermix.",
        value: Source.boolean(block, :advertise_mdns, false),
        restart: restart,
        advanced: true
      )
    ]
  end
end
