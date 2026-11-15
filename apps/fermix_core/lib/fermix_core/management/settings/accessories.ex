defmodule FermixCore.Management.Settings.Accessories do
  @moduledoc """
  The `accessories` section: `[fermix_channels.accessories] enabled`, the
  switch that lets a StackChan connect to this Mac over USB (M91 E3; config
  in `FermixCore.Accessories.Config`). Under the voice pane, beside the voice
  settings the robot inherits, and only on a Mac: an accessory needs a local
  Mac primary.

  The switch is live: a write starts or stops the accessory link at once
  (`FermixCore.Management.Settings`, `Management.Accessories.apply_enabled/2`),
  and never needs a restart. Everything else an accessory shows (its ports,
  its pairing, its calls) is a runtime fact on `accessories.status`, not a row.
  """

  alias FermixCore.IMessage
  alias FermixCore.Management.Settings.Row
  alias FermixCore.Management.Settings.Source

  @section %{id: "accessories", pane: "voice", title: "StackChan"}

  @doc "The section on a Mac, none elsewhere. `macos?:` names the host for a test."
  @spec sections(keyword()) :: [%{id: String.t(), pane: String.t(), title: String.t()}]
  def sections(opts \\ []) when is_list(opts),
    do: if(macos?(opts), do: [@section], else: [])

  @doc "Whether this module owns the named section on this host."
  @spec owns?(String.t(), keyword()) :: boolean()
  def owns?(section, opts \\ []) when is_binary(section) and is_list(opts),
    do: section == @section.id and macos?(opts)

  @doc "The rows of the owned section."
  @spec rows(String.t(), Source.snapshot()) :: [Row.t()]
  def rows("accessories", snapshot) when is_map(snapshot) do
    block = Source.channel(snapshot, :accessories)

    [
      Row.new("accessories_enabled", :toggle, "Allow a StackChan connection",
        footer:
          "Talk through your robot's microphone and speaker. Your voice model and call " <>
            "limits stay the same.",
        value: Source.boolean(block, :enabled, false),
        restart: Row.restart?([:channels, :accessories, :enabled])
      )
    ]
  end

  defp macos?(opts), do: Keyword.get_lazy(opts, :macos?, &IMessage.macos?/0)
end
