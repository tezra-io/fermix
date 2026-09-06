defmodule FermixCore.Management.Settings.Channels do
  @moduledoc """
  The `channels.<name>` sections and the `editors` section (M34 native setup §5.2).

  Every field inside a channel sub-page comes from here and nothing is
  enumerated by a front-end, so the two doors cannot disagree about what
  WhatsApp needs. A real enable toggle is part of every channel's section:
  pausing a channel is not the same as deleting its token, and until it existed
  the only way to turn one off was to remove the credential.
  """

  alias FermixCore.Management.Settings.Channels.Inventory
  alias FermixCore.Management.Settings.Row
  alias FermixCore.Management.Settings.Source
  alias FermixCore.Readiness

  @prefix "channels."
  @pane "channels"
  @editors_id "editors"

  @doc "Every channel section, plus editors."
  @spec sections() :: [%{id: String.t(), pane: String.t(), title: String.t()}]
  def sections do
    channel_sections =
      Enum.map(Inventory.channels(), fn channel ->
        %{id: section_id(channel), pane: @pane, title: Inventory.title(channel)}
      end)

    channel_sections ++ [%{id: @editors_id, pane: @pane, title: "Editors"}]
  end

  @doc "The section id for one channel."
  @spec section_id(atom()) :: String.t()
  def section_id(channel) when is_atom(channel), do: @prefix <> Atom.to_string(channel)

  @doc "Whether this module owns the named section."
  @spec owns?(String.t()) :: boolean()
  def owns?(@editors_id), do: true

  def owns?(@prefix <> name),
    do: Enum.any?(Inventory.channels(), &(Atom.to_string(&1) == name))

  def owns?(_section), do: false

  @doc "The rows of one owned section."
  @spec rows(String.t(), Source.snapshot()) :: [Row.t()]
  def rows(@editors_id, snapshot) do
    [
      Row.new("acp_enabled", :toggle, "Accept editor connections",
        footer: "Lets an ACP editor talk to Fermix over the local socket.",
        value: Source.boolean(Source.channel(snapshot, :acp), :enabled, false),
        restart: Row.restart?(:acp)
      )
    ]
  end

  def rows(@prefix <> name, snapshot) do
    channel = String.to_existing_atom(name)
    channel_rows(channel, Source.channel(snapshot, channel), snapshot)
  end

  defp channel_rows(channel, block, snapshot) do
    restart = Row.restart?(:channels)

    credential_rows = Enum.map(Inventory.rows(channel), &row(&1, block, snapshot, restart))

    credential_rows ++ [enabled_row(channel, block, restart)]
  end

  defp row({key, _config_key, :secret, label}, _block, snapshot, restart) do
    Row.new(Atom.to_string(key), :secret, label,
      present: Source.secret_present?(snapshot, key),
      restart: restart
    )
  end

  defp row({key, config_key, :text, label}, block, _snapshot, restart) do
    Row.new(Atom.to_string(key), :text, label,
      value: Source.string(block, config_key),
      restart: restart
    )
  end

  # The shipped default differs per channel (Telegram ships on), so the row reads
  # `Readiness`'s own defaults rather than a second copy of them: a channel that
  # readiness treats as enabled must render as enabled.
  defp enabled_row(channel, block, restart) do
    default = Keyword.fetch!(Readiness.channel_defaults(), channel)

    Row.new(Atom.to_string(Inventory.enabled_key(channel)), :toggle, Inventory.title(channel),
      value: Source.boolean(block, :enabled, default),
      restart: restart
    )
  end
end
