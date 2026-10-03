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

  One override, with two users (M56 §4.1, D9): Channels names the
  conversation a message runs in when it is not the message's own, and
  `from/1` answers it, so the queue lane, the history read, the commit, the
  memory review and context tracking all agree without any of them knowing
  which channel joined which conversation, and Core spells no channel for it.

    * A trusted Live hand-off names it in its `voice_call` (`VoiceCall`),
      usually the chat's own. The map is believed only on an operator message
      on the `voice` channel; before ingest a message has no trust, so a
      caller that needs the key then (the voice bridge) names it itself.
    * A channel whose turns join another transport's conversation names it on
      the message, in `conversation_key`: the phone's turns run in the Mac's
      chat, so the one timeline both draw has one agent history. Only the
      gateway puts it there, from the channel's adapter and over anything the
      message carried, so it is believed from ingest on, the command path's
      key included. A malformed one is a defect in that code, and raises.
  """

  alias FermixCore.Agents.VoiceCall

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
    case named(msg) do
      {:ok, conversation_key} -> conversation_key
      :none -> {channel, chat_id, thread_scope(msg)}
    end
  end

  # The conversation Channels named on the message. A message never carries
  # both: the gateway names one only for a channel that joins another's, and
  # the voice channel joins none.
  defp named(%{conversation_key: conversation_key}) when not is_nil(conversation_key),
    do: {:ok, joined!(conversation_key)}

  defp named(msg) do
    case VoiceCall.from_message(msg) do
      {:ok, %{conversation_key: conversation_key}} -> {:ok, conversation_key}
      :none -> :none
    end
  end

  defp joined!({channel, chat_id, thread} = conversation_key)
       when is_binary(channel) and channel != "" and is_binary(chat_id) and chat_id != "" and
              (thread == :root or (is_binary(thread) and thread != "")),
       do: conversation_key

  defp joined!(other),
    do: raise(ArgumentError, "malformed conversation_key on a message: #{inspect(other)}")

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
