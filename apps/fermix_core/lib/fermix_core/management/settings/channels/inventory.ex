defmodule FermixCore.Management.Settings.Channels.Inventory do
  @moduledoc """
  The credential rows each messaging channel publishes (M34 native setup §5.2).

  One table, read by the descriptor, the answer map and `FermixCore.Readiness`,
  so the keys a pane renders, the keys a write accepts and the keys readiness
  requires cannot diverge. Every entry names the channel-block key it reads and
  whether it is a secret; the row key is the wizard answer key, which is what
  makes the round trip a fact rather than a translation.

  Two tables of the same five channels is how `signal` came to be `[:account]`
  in one place and `{:signal_account, :account, :text, "Signal account"}` in the
  other, and how a channel added to one would have been invisible to the other.
  """

  @channels [
    telegram: %{
      title: "Telegram",
      rows: [
        {:telegram_bot_token, :bot_token, :secret, "Bot token"},
        {:telegram_owner_user_id, :owner_user_id, :text, "Your Telegram user ID"}
      ]
    },
    whatsapp: %{
      title: "WhatsApp",
      rows: [
        {:whatsapp_access_token, :access_token, :secret, "Access token"},
        {:whatsapp_verify_token, :verify_token, :secret, "Verify token"},
        {:whatsapp_app_secret, :app_secret, :secret, "App secret"},
        {:whatsapp_phone_number_id, :phone_number_id, :text, "Phone number ID"},
        {:whatsapp_owner_user_id, :owner_user_id, :text, "Your WhatsApp ID"}
      ]
    },
    discord: %{
      title: "Discord",
      rows: [
        {:discord_bot_token, :bot_token, :secret, "Bot token"},
        {:discord_bot_user_id, :bot_user_id, :text, "Bot user ID"},
        {:discord_owner_user_id, :owner_user_id, :text, "Your Discord user ID"}
      ]
    },
    # Slack takes events by webhook (the default) or over Socket Mode (M75),
    # and each way needs its own credential beside the bot token: the webhook
    # checks Slack's signature, and Socket Mode opens its connection with the
    # app-level token.
    slack: %{
      title: "Slack",
      rows: [
        {:slack_mode, :mode, :choice, "Receive events through"},
        {:slack_bot_token, :bot_token, :secret, "Bot token"},
        {:slack_signing_secret, :signing_secret, :secret, "Signing secret"},
        {:slack_app_token, :app_token, :secret, "App-level token"},
        {:slack_owner_user_id, :owner_user_id, :text, "Your Slack user ID"}
      ],
      choices: %{
        slack_mode: %{
          default: "webhook",
          options: [
            {"webhook", "A webhook at a public address"},
            {"socket", "Socket Mode, with no public address"}
          ]
        }
      },
      modes: [webhook: [:signing_secret], socket: [:app_token]]
    },
    signal: %{
      title: "Signal",
      rows: [
        {:signal_account, :account, :text, "Signal account"},
        {:signal_owner_user_id, :owner_user_id, :text, "Your Signal number"}
      ]
    },
    # M54. It carries no token, so it has no secret row at all, and no account
    # choice: the helper derives the account when it confirms the recipients.
    imessage: %{
      title: "iMessage",
      platform: :macos,
      rows: [
        {:imessage_owner_user_id, :owner_user_id, :text, "Your Apple ID or phone number"},
        {:imessage_allowed_sender_ids, :allowed_sender_ids, :list, "Guests"}
      ]
    }
  ]

  # The rows that name PEOPLE rather than the connection: the operator, and on
  # iMessage the guests. Every other row is something the channel cannot run
  # without, which is what `Readiness.channel_configured?/1` requires.
  @people_keys [:owner_user_id, :allowed_sender_ids]

  @typedoc "One row: the answer key, the channel-block key it reads, its kind and its label."
  @type row_spec :: {atom(), atom(), :secret | :text | :list | :choice, String.t()}

  @typedoc "A choice row's default value and its options, each `{value, label}`."
  @type choice :: %{default: String.t(), options: [{String.t(), String.t()}]}

  @doc "Every channel, in publication order."
  @spec channels() :: [atom()]
  def channels, do: Keyword.keys(@channels)

  @doc "One channel's credential rows."
  @spec rows(atom()) :: [row_spec()]
  def rows(channel) when is_atom(channel), do: Keyword.fetch!(@channels, channel).rows

  @doc "One channel's section title."
  @spec title(atom()) :: String.t()
  def title(channel) when is_atom(channel), do: Keyword.fetch!(@channels, channel).title

  @doc "One choice row's default and options."
  @spec choice(atom(), atom()) :: choice()
  def choice(channel, key) when is_atom(channel) and is_atom(key),
    do: @channels |> Keyword.fetch!(channel) |> Map.fetch!(:choices) |> Map.fetch!(key)

  @doc """
  The channel-block keys one channel needs before it can run, in row order,
  under its block's `mode` where its credentials depend on it (Slack): a choice
  is a setting rather than a credential, and a credential only another mode
  uses is not needed. With no block, the channel's first mode.
  """
  @spec credential_keys(atom(), keyword()) :: [atom()]
  def credential_keys(channel, block \\ []) when is_atom(channel) and is_list(block) do
    entry = Keyword.fetch!(@channels, channel)
    unused = other_modes_keys(entry, block)

    entry.rows
    |> Enum.reject(fn {_key, config_key, kind, _label} ->
      kind == :choice or config_key in @people_keys or config_key in unused
    end)
    |> Enum.map(&elem(&1, 1))
  end

  defp other_modes_keys(%{modes: [{first, _keys} | _rest] = modes}, block) do
    mode = Keyword.get(block, :mode, first)
    modes |> Keyword.delete(mode) |> Keyword.values() |> List.flatten()
  end

  defp other_modes_keys(_entry, _block), do: []

  @doc "The enable row's key for one channel."
  @spec enabled_key(atom()) :: atom()
  def enabled_key(channel) when is_atom(channel), do: :"#{channel}_enabled"

  @doc "Whether the named channel has a section."
  @spec known?(atom()) :: boolean()
  def known?(channel) when is_atom(channel), do: Keyword.has_key?(@channels, channel)

  @doc """
  Whether a channel exists on this host. iMessage exists only on the Mac whose
  Messages it reads, so off a Mac no surface offers it; every other channel
  exists everywhere.
  """
  @spec available?(atom(), boolean()) :: boolean()
  def available?(channel, macos?) when is_atom(channel) and is_boolean(macos?) do
    case Keyword.fetch!(@channels, channel) do
      %{platform: :macos} -> macos?
      %{} -> true
    end
  end

  @doc "The channels that exist on this host, in publication order."
  @spec available_channels(boolean()) :: [atom()]
  def available_channels(macos?) when is_boolean(macos?),
    do: Enum.filter(channels(), &available?(&1, macos?))
end
