defmodule FermixCore.Agents.LiveCallTurn do
  @moduledoc """
  A message typed in the chat while a GPT-Live call in the chat is up (M56
  §4.4, D7): a chat turn that knows the call is up, can read it
  (`voice_call_context`), and may end without a reply.

  `MainAgent` freezes the call into the turn's snapshot at checkout as
  `live_call` (`VoiceBridge.chat_call/2`: when it started, and whether the turn
  may end with no reply), so a message that waited in the queue is judged
  when it runs. Only an owner's turn of the chat's own conversation is told,
  never a hand-off, which is the call's own turn, and never anything of a
  private call. Nothing comes from a client payload.

  The turn is told in one system line (`note/1`), which exists only while the
  call does, so the prompt cache breaks twice per call rather than every
  turn. The silent ending is the convention jobs and reminders already use: a
  reply that is exactly `[SILENT]`. It is honoured only on a turn whose
  snapshot allowed it (`silent?/2`); anywhere else it is ordinary text.
  """

  @sentinel "[SILENT]"

  @typedoc "The call as the snapshot holds it, or `nil` when the turn was told of none."
  @type live_call :: %{started_at: DateTime.t(), silence_allowed?: boolean()} | nil

  @doc "The reply that ends a turn with nothing shown."
  @spec sentinel() :: String.t()
  def sentinel, do: @sentinel

  @doc """
  The system line a turn of the chat is told during a call, or `nil` when the
  snapshot names no call. With an older companion client attached the turn may
  not stay silent, and is told to answer briefly instead.
  """
  @spec note(live_call()) :: String.t() | nil
  def note(nil), do: nil

  def note(%{started_at: %DateTime{} = started_at, silence_allowed?: silence_allowed?})
      when is_boolean(silence_allowed?) do
    "A voice call with the owner started at #{clock(started_at)} UTC and is still in " <>
      "progress. A message typed in this chat now may be material for the call rather " <>
      "than a request to you. Reply in writing when the message asks for something or " <>
      "needs an answer. " <>
      otherwise(silence_allowed?) <>
      " `voice_call_context` reads what has been said on the call."
  end

  @doc """
  Whether a turn's final reply ends it with nothing shown: the snapshot
  allowed silence and the reply is the sentinel, whitespace aside.
  """
  @spec silent?(live_call(), String.t()) :: boolean()
  def silent?(%{silence_allowed?: true}, response) when is_binary(response),
    do: sentinel?(response)

  def silent?(_live_call, response) when is_binary(response), do: false

  @doc "Whether `text` is the sentinel, whitespace aside."
  @spec sentinel?(String.t()) :: boolean()
  def sentinel?(text) when is_binary(text), do: String.trim(text) == @sentinel

  @doc """
  Whether `text`, a reply streamed so far, could still become the sentinel. A
  stream relay holds such a draft back, so a silent ending never shows one.
  """
  @spec sentinel_prefix?(String.t()) :: boolean()
  def sentinel_prefix?(text) when is_binary(text),
    do: String.starts_with?(@sentinel, String.trim(text))

  defp otherwise(true),
    do: "Otherwise reply with exactly #{@sentinel} and nothing else: nothing is shown."

  defp otherwise(false), do: "Otherwise acknowledge it briefly, in a few words."

  defp clock(started_at),
    do: started_at |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%H:%M")
end
