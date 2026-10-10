defmodule FermixCore.Management.Settings.Mobile do
  @moduledoc """
  The `channels.mobile` section: the phone channel's own switches (M51
  management pairing §6).

  A section of its own rather than a channels-inventory entry, because the
  inventory expresses credential rows and the phone channel has none: it needs
  a toggle, a port and an address. Every row is a projection of the one
  `[fermix_channels.mobile]` block, and every one is boot-bound, because the
  listener and the local-network announcement are started once per boot.

  Identity and protocol version are runtime facts rather than settings, so
  they are published on `mobile.status` and are not rows here.
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

    [
      Row.new("mobile_enabled", :toggle, "Phone companion",
        footer: "Lets a paired phone chat with this Fermix over your network.",
        value: Source.boolean(block, :enabled, false),
        restart: restart
      ),
      Row.new("mobile_port", :number, "Port",
        footer: "The phone reaches this port. Change it only if something else uses it.",
        value: Source.number(block, :port, @default_port),
        min: 1_024,
        max: 65_535,
        step: 1,
        format: :integer,
        restart: restart
      ),
      Row.new("mobile_bind", :text, "Listen on",
        footer:
          "Every network by default, or one address, such as your Tailscale IP, " <>
            "to listen only there.",
        value: Source.string(block, :bind, @default_bind),
        restart: restart
      ),
      Row.new("mobile_advertise_mdns", :toggle, "Announce on the local network",
        footer: "Off when you want the phone to reach this machine only over Tailscale.",
        value: Source.boolean(block, :advertise_mdns, true),
        restart: restart
      )
    ]
  end
end
