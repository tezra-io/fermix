defmodule FermixChannels.Gateway.Channel do
  @moduledoc """
  Behaviour for channel integrations (Telegram, WhatsApp, Discord, etc.)

  Channels are the interface between external messaging platforms and the
  agent. Each channel must parse inbound webhooks into standard messages,
  send outbound messages, and optionally verify webhook authenticity.
  """

  alias FermixCore.Reply

  @type message :: FermixChannels.Gateway.Message.t()

  @type send_opts :: [
          reply_to: String.t(),
          parse_mode: String.t(),
          message_thread_id: String.t() | integer(),
          thread_ts: String.t()
        ]

  @type media_part :: Reply.media_part()
  @type reply_fn :: Reply.reply_fn()

  @doc """
  Parse a webhook payload into messages.

  Channels that do not support webhook ingress should return
  `{:error, :unsupported_transport}` so webhook controllers can treat the
  request as an invalid transport rather than an auth failure.
  """
  @callback parse_webhook(map()) :: {:ok, [message()]} | {:error, term()}

  @doc """
  Send a message to a chat.

  The behaviour contract is always 3-arity. Channel implementations may expose
  a 2-arity convenience wrapper by defaulting `opts` to `[]`.
  """
  @callback send_message(String.t(), String.t(), send_opts()) :: :ok | {:error, term()}

  @doc "Send an attachment to a chat."
  @callback send_media(String.t(), media_part(), send_opts()) :: :ok | {:error, term()}

  @doc "Build a text reply function for a normalized inbound message."
  @callback build_text_reply(message()) :: (String.t() -> :ok | {:error, term()})

  @doc "Build an attachment reply function for a normalized inbound message."
  @callback build_media_reply(message()) :: (media_part() -> :ok | {:error, term()})

  @doc """
  Download an attachment to a local temp path for shared runtime processing.

  Voice/audio-capable channels can implement this callback to opt into the
  shared transcription path without embedding speech-to-text logic in the
  channel adapter itself.
  """
  @callback download_attachment(message(), map()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Verify webhook authenticity (HMAC, token, etc.).

  Channels without webhook transport should return `{:error, :unsupported_transport}`.
  """
  @callback verify_webhook(Plug.Conn.t()) :: :ok | {:error, term()}

  @doc "Start typing indicator (optional)"
  @callback start_typing(String.t()) :: :ok

  @optional_callbacks [start_typing: 1, download_attachment: 2]
end
