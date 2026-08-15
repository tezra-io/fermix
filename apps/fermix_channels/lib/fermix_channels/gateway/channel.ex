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
          thread_ts: String.t(),
          reply_markup: map()
        ]

  @type media_part :: Reply.media_part()
  @type reply_fn :: Reply.reply_fn()
  @type health_result ::
          {:ok, %{required(:detail) => String.t(), optional(:latency_ms) => non_neg_integer()}}
          | {:error, term()}

  @typedoc "Opaque draft handle owned by the channel (Telegram: integer message_id)."
  @type stream_handle :: term()

  @typedoc """
  How an inbound message participates in album coalescing (M14).

    * `{:coalesce, key}` — buffer under `key` with a reset-on-each-part debounce.
    * `{:flush, key}` — flush a pending album under `key`, then dispatch this
      message as its own turn (a trailing message that shares the album's key).
    * `:passthrough` — dispatch immediately, touching no buffer.
  """
  @type album_classification :: {:coalesce, term()} | {:flush, term()} | :passthrough

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
  it can render a live draft of the reply while the turn runs.

  `:raw` — a machine surface that appends exact deltas to its own wire
  (M29 §8.4). The gateway hands the turn the channel-built callback directly:
  no draft engine, no chunking, and the per-channel `streaming` config is never
  consulted.

  Channels without the callback (or returning `:none`) stay typing-only; the
  gateway resolves this once per turn, never mid-run.
  """
  @callback stream_capability() :: :draft_edit | :raw | :none

  @doc """
  Build the `:raw` tier's stream callback for an inbound message. Receives each
  `FermixCore.AgentLoop.stream_event()` as a plain map and appends the exact
  suffix to the channel's wire. Only `:raw` channels implement it.
  """
  @callback build_raw_stream_callback(message()) :: (map() -> :ok)

  @doc """
  Build a tool-lifecycle callback for an inbound message (M29 §4). The turn
  invokes it with each tool start/finish event so a machine surface can mirror
  activity to its client. Channels without it run turns with no activity feed.
  """
  @callback build_activity_callback(message()) :: (term() -> any())

  @doc """
  Build the terminal turn-outcome callback for an inbound message (M29 §4).
  Invoked exactly once per turn with `{:completed}`, `{:cancelled}`, or
  `{:failed, reason}` — the raw reason, before any user-facing stringification.
  Channels without it learn a turn's fate only through the reply itself.
  """
  @callback build_turn_result(message()) :: (term() -> any())

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

  @typedoc """
  Draft-rotation parameters (CHANNEL_LONGFORM_PRESENTATION §6): how this channel
  measures a message's rendered length, and the card size at which the streaming
  engine seals the live bubble and opens a fresh one.
  """
  @type rotation_spec :: %{
          measure: (String.t() -> non_neg_integer()),
          rotate_at: pos_integer()
        }

  @doc """
  Rotation parameters for a draft-capable channel. The gateway resolves this
  once per turn into plain data (a closure plus an integer) so the engine can
  rotate without ever knowing which channel it is writing to. A draft-capable
  channel without this callback simply never rotates: its draft freezes at the
  channel's own message limit.
  """
  @callback rotation_spec() :: rotation_spec()

  @doc """
  Classify an inbound message for album coalescing (`Gateway.AlbumBuffer`).

  Only channels that deliver a multi-image album as several separate inbound
  messages (Telegram media groups, WhatsApp per-image webhooks) implement this;
  channels without it never run an album buffer.
  """
  @callback album_classify(message()) :: album_classification()

  @typedoc """
  Reaction support this channel offers (docs/design/EMOJI_REACTION_ACKS.md §5.2).

    * `:none` — no reactions (or the callback is unimplemented). The gateway
      never advertises the `react` tool for this channel.
    * `:any_emoji` — any single emoji is accepted (Discord, WhatsApp, Signal).
    * `{:restricted, set}` — a fixed allowed set (Telegram); the gateway builds
      the tool's emoji enum from it so the model can only pick a supported glyph.
  """
  @type reaction_capability :: :none | :any_emoji | {:restricted, [String.t()]}

  @doc """
  Place a single-emoji reaction on an inbound message. The full `message()` is
  passed so the adapter reads the exact platform reaction target from it
  (Telegram `message_id` + `chat_id`, Discord snowflake, …). Only channels that
  support reactions implement this; the gateway gates on `function_exported?`.
  """
  @callback react(message(), emoji :: String.t()) :: :ok | {:error, term()}

  @doc """
  The reaction capability the gateway resolves once per turn into plain data
  (the allowed emoji set) and hands to core — never the channel module itself.
  Unimplemented is treated as `:none`.
  """
  @callback reaction_capability() :: reaction_capability()

  @doc """
  Deliver an owner-approval prompt with a one-tap approve affordance
  (SANDBOX_ACCESS_APPROVAL_FLOW). `token` is the single-use confirmation token;
  the channel renders an affordance (Telegram: an inline "Approve" button whose
  callback data is the token) so a tap funnels back through the normal
  `/confirm <token>` path. Only channels that support one-tap approval implement
  it; `Delivery` gates on `function_exported?` and falls back to plain text
  (which already carries the tap-to-copy `/confirm` command) otherwise.
  """
  @callback send_approval(message(), text :: String.t(), token :: String.t()) ::
              :ok | {:error, term()}

  @doc """
  Deliver a skill-curation proposal with two-tap approve/deny affordances
  (MILESTONE_26_SKILL_CURATION §6.6). Target-addressed — proposals are
  proactive, there is no inbound message to reply to — with `target` carrying
  at least `:chat_id`. The adapter builds its own button row from the bare
  `token` via `ProposalButton.approve_payload/1` / `deny_payload/1`; a tap
  funnels back through the typed `/skills approve|deny <token>` path.
  `Delivery.ChannelSend` gates on `function_exported?`; channels without it
  get the same text with the typed commands spelled out.
  """
  @callback send_proposal(target :: map(), text :: String.t(), token :: String.t()) ::
              :ok | {:error, term()}

  @doc """
  Send text the sender is not notified about, answering with the platform ids
  of every message it created (CHANNEL_LONGFORM_PRESENTATION §5).

  This is how the streaming engine posts its 💭 thought stream: silent while the
  answer is being produced, then deleted through `delete_message/2` once the
  answer lands. A channel that cannot do both gets no thought stream at all
  (decision §9.2), so implement this only alongside `delete_message/2`.
  """
  @callback send_ephemeral(message(), text :: String.t()) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc """
  Delete one previously sent message by its platform id (the ids
  `send_ephemeral/2` returned). Best-effort at the call site: the engine logs a
  failure and never retries it, so a refusal must be returned, never raised.
  """
  @callback delete_message(message(), message_id :: String.t()) :: :ok | {:error, term()}

  @optional_callbacks [
    start_typing: 1,
    download_attachment: 2,
    health_check: 1,
    stream_capability: 0,
    build_raw_stream_callback: 1,
    build_activity_callback: 1,
    build_turn_result: 1,
    open_draft: 2,
    edit_draft: 3,
    seal_draft: 3,
    discard_draft: 2,
    rotation_spec: 0,
    album_classify: 1,
    react: 2,
    reaction_capability: 0,
    send_approval: 3,
    send_proposal: 3,
    send_ephemeral: 2,
    delete_message: 2
  ]
end
