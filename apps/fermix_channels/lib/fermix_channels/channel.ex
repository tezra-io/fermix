defmodule FermixChannels.Channel do
  @moduledoc """
  Behaviour for channel integrations (Telegram, WhatsApp, Discord, etc.)

  Channels are the interface between external messaging platforms and the
  agent. Each channel must parse inbound webhooks into standard messages,
  send outbound messages, and optionally verify webhook authenticity.
  """

  @type message :: FermixChannels.Message.t()

  @type send_opts :: [
          reply_to: String.t(),
          parse_mode: String.t(),
          message_thread_id: integer()
        ]

  @type reply_fn :: (String.t() -> :ok | {:error, term()})

  @doc "Parse a webhook payload into messages"
  @callback parse_webhook(map()) :: {:ok, [message()]} | {:error, term()}

  @doc "Send a message to a chat"
  @callback send_message(String.t(), String.t(), send_opts()) :: :ok | {:error, term()}

  @doc "Build a reply function for a normalized inbound message"
  @callback build_reply(message()) :: reply_fn()

  @doc "Verify webhook authenticity (HMAC, token, etc.)"
  @callback verify_webhook(Plug.Conn.t()) :: :ok | {:error, term()}

  @doc "Start typing indicator (optional)"
  @callback start_typing(String.t()) :: :ok

  @optional_callbacks [start_typing: 1]
end
