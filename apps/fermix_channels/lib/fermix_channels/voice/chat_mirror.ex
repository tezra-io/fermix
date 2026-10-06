defmodule FermixChannels.Voice.ChatMirror do
  @moduledoc """
  What is typed in the chat during a Live call, told to the call (M56 §4.3).

  A message the owner types in the chat, and the chat's answer to it, reach
  the voice model as one quiet line each, so "use that link" said aloud has
  something to hand off; the hand-off then reads the chat itself, being in the
  chat's conversation. `Companion.Turns` calls `typed/2` as it hands a chat
  turn to the queue and `answered/1` as that turn completes, so a slash command
  answered without a turn, or a request cancelled before it was queued, is
  never told. The call is found in Core's registry, whose claim says whether
  it is in the chat, so a private call is never told and its chat never read;
  `LiveSessionServer` drops what a call not yet up must not hear.

  Only the chat's own conversation is mirrored, because only it is what a
  hand-off can read. The phone's turns run in it too (M56 D9), so a message
  typed on the phone is told like one typed on the Mac, and its answer from
  its turn's outcome in `Turns`, as the Mac's is: the phone writes its own
  reply rows, but every turn of both transports ends there, once.

  Nothing here may fail the turn it rides on or crash `Turns`: both functions
  answer `:ok`, and a chat that cannot be read is logged.
  """

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Voice.Bridge
  alias FermixCore.Agents.ConversationKey
  alias FermixCore.Realtime.CallRegistry
  alias FermixCore.Realtime.LiveSessionServer

  require Logger

  @doc "Tell a call in progress that the owner typed `text` in the conversation `key`."
  @spec typed(ConversationKey.t(), String.t()) :: :ok
  def typed(key, text) when is_tuple(key) and is_binary(text) do
    case chat_call(key) do
      {:ok, session} -> LiveSessionServer.chat_typed(session, text)
      :none -> :ok
    end
  end

  @doc """
  Tell a call in progress what the chat answered, once a turn in the
  conversation `key` completed: the chat's newest message, when it is the
  answer.
  """
  @spec answered(ConversationKey.t()) :: :ok
  def answered(key) when is_tuple(key) do
    with {:ok, session} <- chat_call(key),
         {:ok, message} <- newest_answer() do
      LiveSessionServer.chat_answered(session, message)
    else
      :none -> :ok
    end
  end

  defp chat_call(key) do
    with true <- key == Companion.chat_conversation_key(),
         {:ok, %{session: session, conversation: "chat"}} <- CallRegistry.active(CallRegistry) do
      {:ok, session}
    else
      _no_call -> :none
    end
  end

  # The turn has committed its answer and still holds its queue lane (its
  # outcome fires before the next turn starts), so the chat's newest message
  # is that answer, with its Computer History marker. Read through the bridge,
  # the one reader of the chat for a call.
  defp newest_answer do
    case Bridge.conversation_window(%{messages: 1, gists: 0}) do
      {:ok, %{messages: [%{role: "assistant"} = message]}} -> {:ok, message}
      {:ok, _no_answer} -> :none
    end
  catch
    :exit, reason ->
      Logger.warning("voice chat mirror: the chat's answer could not be read: #{inspect(reason)}")
      :none
  end
end
