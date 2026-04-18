defmodule FermixChannels.Message do
  @moduledoc """
  Normalized inbound message from any channel.

  Every channel adapter parses platform-specific payloads into this struct,
  giving the agent a uniform interface regardless of source.

  `thread_scope` is a root/thread presence marker derived from `thread_ts`.
  The actual platform thread identifier lives in `thread_ts`, and that value is
  what the shared runtime uses for thread-aware conversation identity.
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
    thread_scope: :root,
    metadata: %{},
    attachments: []
  ]

  @type thread_scope :: :root | :thread
  @type thread_id :: String.t() | integer()

  @type t :: %__MODULE__{
          id: String.t(),
          content: String.t(),
          sender: String.t(),
          channel: String.t(),
          chat_id: String.t(),
          reply_target: String.t(),
          thread_ts: thread_id() | nil,
          thread_scope: thread_scope(),
          metadata: map(),
          attachments: [map()]
        }

  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    attrs
    |> Map.put(:thread_scope, thread_scope(attrs))
    |> then(&struct!(__MODULE__, &1))
  end

  defp thread_scope(%{thread_ts: nil}), do: :root
  defp thread_scope(%{thread_ts: _thread_ts}), do: :thread
  defp thread_scope(_attrs), do: :root
end
