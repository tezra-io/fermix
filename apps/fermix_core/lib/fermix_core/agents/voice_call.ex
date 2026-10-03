defmodule FermixCore.Agents.VoiceCall do
  @moduledoc """
  The one gate every voice seam reads (MILESTONE_41_OPENAI_LIVE_VOICE.md §5.1/§7).

  Under the `openai_live` engine a voice call delegates each task to an ordinary
  Core turn, and that turn needs context no channel message may supply for
  itself: which conversation it runs in and which `ConversationStore` holds it,
  which call and trace session the turn belongs to, which revision fences it,
  and the Live-only prompt addendum. `FermixChannels.Voice.Bridge` builds that
  map; this module is what decides whether to believe it.

  The conversation is `conversation_key` (M56 §4.1): the chat's own, named by
  Channels so Core never spells a channel, or, for a private call, one keyed
  by the call's UUID. `ConversationKey.from/1` answers it for a trusted turn,
  so every reader of the key agrees. `conversation` is the call's mode
  (`"chat"` or `"private"`, M56 §5), which the capability boundary is read for
  (`excluded_categories/1`).

  Two conditions, both necessary: the message arrived on the `"voice"` channel
  AND the gateway authorized it as `:operator`. Anything else answers `:none` —
  a crafted `voice_call` on a Telegram message must never redirect history,
  correlation, or the prompt. A map that clears the gate and is still malformed
  is a defect in trusted code, so it raises rather than degrading to `:none`
  (which would silently run the turn against the global store).

  Consumers: `ConversationKey.from/1` (the conversation), `MainAgent.turn_state/2`
  (store override, memory-review skip), `TurnRunner` (session ids, origin,
  prompt addendum, the persisted request) and `FermixChannels.Gateway.Queue`
  (stopped-marker store).
  """

  # The voice capability boundary (M41 §5.1), in ONE place because two surfaces
  # read it and a disagreement between them is invisible: `LivePrompt` names
  # these categories to the voice model, and `TurnRunner` builds the delegation
  # turn's profile from the same list. A category here is one a voice call
  # cannot honestly deliver, whatever its mode:
  #
  #   * `:channel` — no `reply_fn`; the call speaks, it does not post.
  #   * `:media` — generation egresses through a channel reply the call has not got.
  #   * `:delegation` — a blocking fan-out does not fit a live conversation.
  #
  # `:delivery` is never here: a send to the owner's named channel
  # (`send_to_channel`) goes out on that channel, not the call's.
  @excluded_categories [:channel, :media, :delegation]

  # A coding run outlives the call that launched it and reports back into the
  # conversation it was launched from (its delivery snapshot is that
  # conversation's, `Harness.Delivery.resolve_snapshot/2`). A call in the chat
  # launches it in the chat's own conversation (M56 §4.7), so its outcome
  # re-enters the chat as a companion turn and is answered there, with no
  # delegation to answer. A private call's conversation ends with the call, so
  # there the outcome would re-enter on the voice channel with nothing left to
  # answer it, and the run's result would be lost: a private call keeps
  # `:harness` out.
  @private_excluded_categories @excluded_categories ++ [:harness]

  @typedoc """
  The delegation context a Live session attaches to its Core turn.
  `conversation_store` is the call-owned ephemeral store (a pid) or the global
  store (a module) when the hand-off runs in the chat or the call persists.
  `call_uuid` is the call's durable identity; `call_id` the trace session.
  """
  @type t :: %{
          call_id: String.t(),
          call_uuid: String.t(),
          conversation: String.t(),
          conversation_key: FermixCore.Agents.ConversationKey.t(),
          delegation_id: String.t(),
          revision: pos_integer(),
          turn_session_id: String.t(),
          conversation_store: GenServer.server(),
          prompt_addendum: String.t(),
          persist?: boolean()
        }

  @doc """
  Capability categories a voice call in `conversation` (`"chat"` or
  `"private"`) excludes, prompt and wire alike.

  The single list `FermixCore.Realtime.LivePrompt` advertises against and
  `FermixCore.Agents.TurnRunner` builds a delegation's profile with, so the
  voice model can never be told about a capability its delegation would not be
  given — the M28 lesson that the prose and the wire move together. A private
  call excludes coding runs too, since its conversation ends with it.
  """
  @spec excluded_categories(String.t()) :: [atom()]
  def excluded_categories("chat"), do: @excluded_categories
  def excluded_categories("private"), do: @private_excluded_categories

  @doc """
  The message's voice-call context, or `:none` when this is not a trusted voice
  turn. Raises `ArgumentError` on a malformed map that cleared the trust gate.
  """
  @spec from_message(map()) :: {:ok, t()} | :none
  def from_message(msg) when is_map(msg) do
    metadata = Map.get(msg, :metadata) || %{}

    trusted(
      Map.get(msg, :source_trust),
      Map.get(msg, :channel),
      Map.get(metadata, :voice_call)
    )
  end

  defp trusted(:operator, "voice", voice_call) when is_map(voice_call),
    do: {:ok, validate!(voice_call)}

  defp trusted(_trust, _channel, _voice_call), do: :none

  defp validate!(voice_call) do
    if valid?(voice_call) do
      voice_call
    else
      raise ArgumentError,
            "malformed voice_call on a trusted voice turn: #{inspect(voice_call)}"
    end
  end

  # The head demands every field, so a map missing one is malformed by shape
  # alone and the fallback clause below rejects it.
  defp valid?(
         %{
           revision: revision,
           conversation: conversation,
           conversation_store: conversation_store,
           conversation_key: conversation_key,
           persist?: persist?
         } = voice_call
       ) do
    identifiers?(voice_call) and revision?(revision) and conversation in ["chat", "private"] and
      store?(conversation_store) and conversation_key?(conversation_key) and is_boolean(persist?)
  end

  defp valid?(_incomplete), do: false

  defp identifiers?(%{
         call_id: call_id,
         call_uuid: call_uuid,
         delegation_id: delegation_id,
         turn_session_id: turn_session_id,
         prompt_addendum: prompt_addendum
       }) do
    text?(call_id) and text?(call_uuid) and text?(delegation_id) and text?(turn_session_id) and
      text?(prompt_addendum)
  end

  defp identifiers?(_incomplete), do: false

  defp text?(value), do: is_binary(value) and value != ""

  defp revision?(value), do: is_integer(value) and value >= 1

  # The canonical shape `ConversationKey` derives: a thread segment is `:root`
  # or the platform's thread id as a string.
  defp conversation_key?({channel, chat_id, thread_scope}),
    do: text?(channel) and text?(chat_id) and (thread_scope == :root or text?(thread_scope))

  defp conversation_key?(_other), do: false

  # A pid (the call-owned ephemeral store) or a registered name (the global
  # store). `nil` is neither, and would silently route the turn's history at the
  # ConversationStore default.
  defp store?(value), do: is_pid(value) or (is_atom(value) and not is_nil(value))
end
