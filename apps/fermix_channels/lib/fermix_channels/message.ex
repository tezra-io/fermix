defmodule FermixChannels.Message do
  @moduledoc """
  Normalized inbound message from any channel.

  Every channel adapter parses platform-specific payloads into this struct,
  giving the agent a uniform interface regardless of source.
  """

  @enforce_keys [:id, :content, :sender, :channel, :chat_id, :reply_target]
  defstruct [
    :id,
    :content,
    :sender,
    :channel,
    :chat_id,
    :reply_target,
    :thread_ts,
    metadata: %{},
    attachments: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          content: String.t(),
          sender: String.t(),
          channel: String.t(),
          chat_id: String.t(),
          reply_target: String.t(),
          thread_ts: String.t() | nil,
          metadata: map(),
          attachments: [map()]
        }
end
