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
  @type health_result ::
          {:ok, %{required(:detail) => String.t(), optional(:latency_ms) => non_neg_integer()}}
          | {:error, term()}

  @typedoc "Opaque draft handle owned by the channel (Telegram: integer message_id)."
  @type stream_handle :: term()

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

  @doc "Probe configured channel credentials and runtime prerequisites."
  @callback health_check(keyword()) :: health_result()

  @doc """
  Streaming tier this channel supports (docs/design/CHANNEL_STREAMING.md §5.4).

  `:draft_edit` — the channel can create a message and edit it in place, so
  it can render a live draft of the reply while the turn runs. Channels
  without the callback (or returning `:none`) stay typing-only; the gateway
  resolves this once per turn, never mid-run.
  """
  @callback stream_capability() :: :draft_edit | :none

  @doc "Create the live draft message. Returns a handle for later edits."
  @callback open_draft(message(), String.t()) :: {:ok, stream_handle()} | {:error, term()}

  @doc """
  Replace the draft's visible text in place. Receives the full cumulative
  snapshot (the channel re-renders the whole prefix, keeping partial markup
  balanced). Best-effort: never retried; an error stops further edits for
  the turn.
  """
  @callback edit_draft(message(), stream_handle(), String.t()) :: :ok | {:error, term()}

  @doc """
  Final reliable write of the authoritative reply text over the draft
  (retry-wrapped inside the channel). If the text overflows the platform
  limit, seal the largest fitting prefix in place and return the remainder
  for normal delivery; `{:ok, nil}` means the whole text was sealed.
  """
  @callback seal_draft(message(), stream_handle(), String.t()) ::
              {:ok, String.t() | nil} | {:error, term()}

  @doc "Delete the draft (turn stopped, superseded, or errored)."
  @callback discard_draft(message(), stream_handle()) :: :ok | {:error, term()}

  @optional_callbacks [
    start_typing: 1,
    download_attachment: 2,
    health_check: 1,
    stream_capability: 0,
    open_draft: 2,
    edit_draft: 3,
    seal_draft: 3,
    discard_draft: 2
  ]
end
