defmodule FermixCore.Management.Settings.Channels do
  @moduledoc """
  The `channels.<name>` sections and the `editors` section (M34 native setup §5.2).

  Every field inside a channel sub-page comes from here and nothing is
  enumerated by a front-end, so the two doors cannot disagree about what
  WhatsApp needs. A real enable toggle is part of every channel's section:
  pausing a channel is not the same as deleting its token, and until it existed
  the only way to turn one off was to remove the credential.
  """

  alias FermixCore.IMessage
  alias FermixCore.Management.Settings.Channels.Inventory
  alias FermixCore.Management.Settings.Row
  alias FermixCore.Management.Settings.Source
  alias FermixCore.Readiness

  @prefix "channels."
  @pane "channels"
  @editors_id "editors"

  @doc """
  Every channel section that exists on this host, plus editors.

  iMessage exists only on a Mac (M54 §12), so off one its section is neither
  published nor readable. `macos?:` names the host for a test.
  """
  @spec sections(keyword()) :: [%{id: String.t(), pane: String.t(), title: String.t()}]
  def sections(opts \\ []) when is_list(opts) do
    channel_sections =
      Enum.map(available_channels(opts), fn channel ->
        %{id: section_id(channel), pane: @pane, title: Inventory.title(channel)}
      end)

    channel_sections ++ [%{id: @editors_id, pane: @pane, title: "Editors"}]
  end

  @doc "The section id for one channel."
  @spec section_id(atom()) :: String.t()
  def section_id(channel) when is_atom(channel), do: @prefix <> Atom.to_string(channel)

  @doc "Whether this module owns the named section on this host."
  @spec owns?(String.t(), keyword()) :: boolean()
  def owns?(section, opts \\ [])

  def owns?(@editors_id, _opts), do: true

  def owns?(@prefix <> name, opts) when is_list(opts),
    do: Enum.any?(available_channels(opts), &(Atom.to_string(&1) == name))

  def owns?(_section, _opts), do: false

  defp available_channels(opts),
    do: Inventory.available_channels(Keyword.get_lazy(opts, :macos?, &IMessage.macos?/0))

  # The one line under a row that needs more than its label. Rows whose label
  # says everything carry none.
  @footers %{
    imessage_posture: "Which Apple ID this Mac's Messages is signed in to.",
    imessage_owner_user_id:
      "The address your iPhone sends iMessages from: an Apple ID email, or a phone number with its country code.",
    imessage_allowed_sender_ids:
      "Other people who may message Fermix here, by Apple ID or phone number. Only with a dedicated account."
  }

  @option_hints %{
    "dedicated_account" =>
      "A separate Apple ID used only by Fermix. You text it from your phone, and guests may join.",
    "own_account" =>
      "Your own Apple ID. Fermix answers only in your conversation with yourself, and nobody else is let in."
  }

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
      footer: footer(key),
      restart: restart
    )
  end

  defp row({key, config_key, :list, label}, block, _snapshot, restart) do
    Row.new(Atom.to_string(key), :list, label,
      value: Source.strings(block, config_key),
      footer: footer(key),
      restart: restart
    )
  end

  # The options are the whole value space, so `settings.apply` refuses any other
  # word under the control that sent it. An unset choice reads as the empty
  # string, which no option carries: nothing is preselected on the operator's
  # behalf (M54 D2, no default posture).
  defp row({key, config_key, :choice, label, options}, block, _snapshot, restart) do
    Row.new(Atom.to_string(key), :choice, label,
      value: Source.string(block, config_key),
      options:
        Enum.map(options, fn {value, option_label} ->
          Row.option(value, option_label, hint: Map.get(@option_hints, value))
        end),
      footer: footer(key),
      restart: restart
    )
  end

  defp footer(key), do: Map.get(@footers, key)

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
