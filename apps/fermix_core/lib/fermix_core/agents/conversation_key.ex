defmodule FermixCore.Agents.ConversationKey do
  @moduledoc """
  Pure derivation of conversation identity `{channel, chat_id, thread_scope}`.

  `thread_ts` is the canonical threaded-conversation identifier when present.
  `thread_scope` is accepted only as a fallback key segment for direct callers
  that do not provide `thread_ts`; channel adapters put platform thread IDs in
  `thread_ts`.

  Shared by `FermixChannels.Gateway.Queue` (FIFO keying) and
  `FermixCore.Agents.TurnRunner` (history/memory scoping). Core-owned; the
  gateway depends on core and may call it.
  """

  @typedoc """
  The canonical thread segment: `:root`, or the platform thread id as a string.
  Platforms whose thread ids are integers (Telegram forum topics) are normalized
  here so one conversation always has ONE key — an inbound turn and a message
  synthesized from a persisted (therefore stringified) thread, such as a harness
  completion continuation, must land in the same conversation and behind the same
  FIFO lane.
  """
  @type thread_scope :: :root | String.t()
  @type t :: {channel :: String.t(), chat_id :: String.t(), thread_scope()}

  @spec from(map()) :: t()
  def from(%{channel: channel, chat_id: chat_id} = msg)
      when is_binary(channel) and is_binary(chat_id) do
    {channel, chat_id, thread_scope(msg)}
  end

  defp thread_scope(%{thread_ts: thread_ts}) when not is_nil(thread_ts),
    do: normalize(thread_ts)

  defp thread_scope(%{thread_scope: thread_scope})
       when thread_scope == :root or is_binary(thread_scope) or is_integer(thread_scope),
       do: normalize(thread_scope)

  defp thread_scope(_msg), do: :root

  defp normalize(:root), do: :root
  defp normalize(value) when is_binary(value), do: value
  defp normalize(value) when is_integer(value), do: Integer.to_string(value)
end
