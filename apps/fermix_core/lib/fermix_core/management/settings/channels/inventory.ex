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
    slack: %{
      title: "Slack",
      rows: [
        {:slack_bot_token, :bot_token, :secret, "Bot token"},
        {:slack_signing_secret, :signing_secret, :secret, "Signing secret"},
        {:slack_owner_user_id, :owner_user_id, :text, "Your Slack user ID"}
      ]
    },
    signal: %{
      title: "Signal",
      rows: [
        {:signal_account, :account, :text, "Signal account"},
        {:signal_owner_user_id, :owner_user_id, :text, "Your Signal number"}
      ]
    }
  ]

  # The one row that names the OPERATOR rather than the connection. Every other
  # row is a credential the channel cannot run without, which is what
  # `Readiness.channel_configured?/1` requires.
  @owner_key :owner_user_id

  @type row_spec :: {atom(), atom(), :secret | :text, String.t()}

  @doc "Every channel, in publication order."
  @spec channels() :: [atom()]
  def channels, do: Keyword.keys(@channels)

  @doc "One channel's credential rows."
  @spec rows(atom()) :: [row_spec()]
  def rows(channel) when is_atom(channel), do: Keyword.fetch!(@channels, channel).rows

  @doc "One channel's section title."
  @spec title(atom()) :: String.t()
  def title(channel) when is_atom(channel), do: Keyword.fetch!(@channels, channel).title

  @doc "The channel-block keys one channel needs before it can run, in row order."
  @spec credential_keys(atom()) :: [atom()]
  def credential_keys(channel) when is_atom(channel) do
    channel
    |> rows()
    |> Enum.reject(&(elem(&1, 1) == @owner_key))
    |> Enum.map(&elem(&1, 1))
  end

  @doc "The enable row's key for one channel."
  @spec enabled_key(atom()) :: atom()
  def enabled_key(channel) when is_atom(channel), do: :"#{channel}_enabled"

  @doc "Whether the named channel has a section."
  @spec known?(atom()) :: boolean()
  def known?(channel) when is_atom(channel), do: Keyword.has_key?(@channels, channel)
end
