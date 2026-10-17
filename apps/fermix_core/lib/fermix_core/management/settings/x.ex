defmodule FermixCore.Management.Settings.X do
  @moduledoc """
  The `channels.x` section: the shared X handle channel's switch (M63).

  A section of its own rather than a channels-inventory entry, because the
  inventory expresses credential rows and this channel has none: Fermix Connect
  holds the bot account's grant, and this installation holds only its pairing,
  which is a key file and a record under the Fermix home rather than a setting.
  The one row is a projection of `[fermix_channels.x] enabled`, which ships off
  because the channel answers people on X and needs the owner's pairing and
  consent first. It is boot-bound: the channel reads it when it starts.

  The pairing, the connection and the Connect origin are runtime facts, so they
  are published on `x.status` and are not rows here.
  """

  alias FermixCore.Management.Settings.Row
  alias FermixCore.Management.Settings.Source

  @section %{id: "channels.x", pane: "channels", title: "X (shared handle)"}

  @doc "The one section this module owns."
  @spec sections() :: [%{id: String.t(), pane: String.t(), title: String.t()}]
  def sections, do: [@section]

  @doc "Whether this module owns the named section."
  @spec owns?(String.t()) :: boolean()
  def owns?(section) when is_binary(section), do: section == @section.id

  @doc "The rows of the owned section."
  @spec rows(String.t(), Source.snapshot()) :: [Row.t()]
  def rows("channels.x", snapshot) when is_map(snapshot) do
    block = Source.channel(snapshot, :x)

    [
      Row.new("x_enabled", :toggle, "Answer mentions of the shared X account",
        footer: "Needs pairing with Fermix Connect. Takes effect the next time Fermix starts.",
        value: Source.boolean(block, :enabled, false),
        restart: Row.restart?([:channels, :x, :enabled])
      )
    ]
  end
end
