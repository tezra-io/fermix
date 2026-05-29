defmodule FermixCore.Agents.ConversationKey do
  @moduledoc """
  Pure derivation of conversation identity `{channel, chat_id, thread_scope}`.

  `thread_ts` is the canonical threaded-conversation identifier when present.
  `thread_scope` is accepted only as a fallback key segment for direct callers
  that do not provide `thread_ts`; channel adapters put platform thread IDs in
  `thread_ts`.

  Shared by `FermixChannels.Gateway.Queue` (single-flight keying) and
  `FermixCore.Agents.TurnRunner` (history/memory scoping). Core-owned; the
  gateway depends on core and may call it.
  """

  @type thread_scope :: :root | String.t() | integer()
  @type t :: {channel :: String.t(), chat_id :: String.t(), thread_scope()}

  @spec from(map()) :: t()
  def from(%{channel: channel, chat_id: chat_id} = msg)
      when is_binary(channel) and is_binary(chat_id) do
    {channel, chat_id, thread_scope(msg)}
  end

  defp thread_scope(%{thread_ts: thread_ts}) when not is_nil(thread_ts), do: thread_ts

  defp thread_scope(%{thread_scope: thread_scope})
       when thread_scope == :root or is_binary(thread_scope) or is_integer(thread_scope),
       do: thread_scope

  defp thread_scope(_msg), do: :root
end
