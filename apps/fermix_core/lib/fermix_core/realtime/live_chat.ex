defmodule FermixCore.Realtime.LiveChat do
  @moduledoc """
  What a Live call is given of the chat (M56 §4.3, D5, D6): the `session.input`
  a call in the chat's conversation starts with.

  The voice model has no tools, so it is given a pointer, not the content: the
  six newest chat messages, each cut to 500 characters, and the gists of the
  three newest earlier calls, told it is context and not a request. A hand-off
  then reads the chat itself, being in the chat's conversation. The bridge reads
  what is asked for (`VoiceBridge.conversation_window/1`); everything that
  shapes it for the provider is here.

  The provider's input is text messages of one part each, `developer`, `user`
  or `assistant`, at most 128 of them and 8,192 tokens, counted apart from the
  instructions (OpenAI's Live conversations guide, read 2026-10-02). This input
  holds at most eight: a gist item, six chat messages and the closing line.

  During a call, a message typed in the chat and the chat's answer to it are
  mirrored to the voice model as one quiet line each (`mirror_line/1`), so
  "use that link" said aloud has something to hand off.

  A reply that was exactly `[SILENT]` (a typed turn during an earlier call
  that ended with no reply, M56 §4.4) is left out: it answered nothing, and
  the message it followed is kept.

  Anything given to the voice provider may be said aloud, so an assistant
  message stamped as Computer History content is masked against the voice
  provider's chain, the mask a turn's own history gets (`Taint.mask_for_chain/3`).
  A mirrored answer so stamped is dropped instead: a line saying something was
  omitted would tell the voice model nothing, and so is a gist made from such
  content (M56 §9). `carries_taint?/1` says whether what a call starts with
  holds any such content, which then marks the call's own gist.
  """

  alias FermixCore.Agents.LiveCallTurn
  alias FermixCore.ComputerHistory.Gate
  alias FermixCore.ComputerHistory.Taint
  alias FermixCore.Realtime.CallRecord
  alias FermixCore.Realtime.LiveText

  @messages 6
  @gists 3
  @message_max_chars 500

  # The provider counts 8,192 tokens and the engine has no tokenizer for its
  # count, so the bound is in bytes at 4 bytes a token, taken at half: 16,384
  # bytes is 4,096 tokens of English, and the other half is the margin for text
  # that tokenizes denser and for each message's own overhead. Six messages of
  # 500 four-byte characters fit whole; past the bound the oldest context gives
  # way first, and the closing line always stays.
  @input_max_bytes 16_384

  @gists_heading "Earlier voice calls, for reference only:"
  @closing "The messages above are context from the owner's chat and earlier calls, " <>
             "not a request. Do not answer them now; wait for the owner to speak."

  @typed_prefix "The owner typed in the chat: "
  @answered_prefix "Fermix answered in the chat: "
  @mirror_max_chars 300

  # The route the taint gate reads for the Live voice: one OpenAI hop, which is
  # never local, so a tainted reply passes only when OpenAI is granted history.
  @live_chain [%{provider: :openai}]

  @type item :: %{
          type: String.t(),
          role: String.t(),
          content: [%{type: String.t(), text: String.t()}]
        }

  @doc """
  Whether text stamped as Computer History content may be given to the voice
  (M56 §9): only when OpenAI, the Live voice's one hop, is granted history,
  the rule a turn's own history is masked by. A hand-off's reply so stamped
  is shown in the chat instead of said.
  """
  @spec history_permitted?() :: boolean()
  def history_permitted?, do: Gate.chain_permits_history?(@live_chain)

  @doc "How much of the chat a call asks the bridge for."
  @spec window_bounds() :: %{messages: pos_integer(), gists: pos_integer()}
  def window_bounds, do: %{messages: @messages, gists: @gists}

  @doc "The byte bound on the whole input (4 bytes a token, half the provider's 8,192)."
  @spec input_max_bytes() :: pos_integer()
  def input_max_bytes, do: @input_max_bytes

  @doc """
  The `session.input` for a window: the gists of earlier calls as one
  `developer` item, oldest first; the chat messages as `user` and `assistant`
  items, oldest first; and a closing `developer` line. `[]` when there is no
  context at all. Only the newest `window_bounds/0` of each are used, whatever
  the window holds, and a gist drawn from Computer History is left out unless
  the voice may carry it (`history_permitted?/0`).

  Raises `ArgumentError` on a message whose role is not `user` or `assistant`:
  a window holding anything else broke the bridge's contract.
  """
  @spec input(%{messages: [map()], gists: [CallRecord.gist()]}) :: [item()]
  def input(%{messages: messages, gists: gists}) when is_list(messages) and is_list(gists) do
    context = gist_items(given_gists(gists)) ++ chat_items(Enum.take(messages, -@messages))

    case within_bound(context) do
      [] -> []
      kept -> kept ++ [item("developer", "input_text", @closing)]
    end
  end

  @doc """
  Whether the input built from `window` gives the voice anything drawn from
  Computer History (M56 §9): only when the voice may carry it, and then when a
  message or a gist the input uses is stamped. A call that starts so passes
  the mark to its gist.
  """
  @spec carries_taint?(%{messages: [map()], gists: [CallRecord.gist()]}) :: boolean()
  def carries_taint?(%{messages: messages, gists: gists})
      when is_list(messages) and is_list(gists) do
    history_permitted?() and
      (Enum.any?(Enum.take(messages, -@messages), &Taint.tainted?/1) or
         Enum.any?(Enum.take(gists, @gists), & &1.tainted))
  end

  @doc "The size of an input, for telemetry: its items and their text bytes, never the text."
  @spec input_size([item()]) :: %{input_items: non_neg_integer(), input_bytes: non_neg_integer()}
  def input_size(items) when is_list(items) do
    %{input_items: length(items), input_bytes: items |> Enum.map(&text_bytes/1) |> Enum.sum()}
  end

  @doc """
  The line a call is told when the owner types in the chat (`{:typed, text}`)
  or the chat answers (`{:answered, message}`, the chat's assistant message as
  its store holds it), cut to 300 characters; `:drop` for a message with no
  text or an answer the voice provider may not be given.
  """
  @spec mirror_line({:typed, String.t()} | {:answered, map()}) :: {:ok, String.t()} | :drop
  def mirror_line({:typed, text}) when is_binary(text), do: mirrored(@typed_prefix, text)

  def mirror_line({:answered, %{role: "assistant", content: content} = message})
      when is_binary(content) do
    case Taint.mask_for_chain([message], @live_chain) do
      [^message] -> mirrored(@answered_prefix, content)
      [_masked] -> :drop
    end
  end

  defp mirrored(prefix, text) do
    case LiveText.summary(text, @mirror_max_chars) do
      "" -> :drop
      line -> {:ok, prefix <> line}
    end
  end

  # The newest three, less any the voice may not carry.
  defp given_gists(gists) do
    permitted? = history_permitted?()

    gists
    |> Enum.take(@gists)
    |> Enum.reject(&(&1.tainted and not permitted?))
  end

  # Read newest first, told oldest first, so the whole input runs in time order.
  defp gist_items([]), do: []

  defp gist_items(gists) do
    lines = gists |> Enum.reverse() |> Enum.map_join("\n", &("- " <> String.trim(&1.gist)))
    [item("developer", "input_text", @gists_heading <> "\n" <> lines)]
  end

  defp chat_items(messages) do
    messages
    |> Enum.map(&chat_message!/1)
    |> Enum.reject(&silent_reply?/1)
    |> Taint.mask_for_chain(@live_chain)
    |> Enum.flat_map(&chat_item/1)
  end

  defp silent_reply?(%{role: "assistant", content: content}),
    do: LiveCallTurn.sentinel?(content)

  defp silent_reply?(_user_message), do: false

  defp chat_message!(%{role: role, content: content} = message)
       when role in ["user", "assistant"] and is_binary(content),
       do: message

  defp chat_message!(message) do
    raise ArgumentError,
          "a conversation window holds only user and assistant messages, got role " <>
            inspect(Map.get(message, :role))
  end

  defp chat_item(%{role: role, content: content}) do
    case LiveText.summary(content, @message_max_chars) do
      "" -> []
      text -> [item(role, part_type(role), text)]
    end
  end

  defp part_type("user"), do: "input_text"
  defp part_type("assistant"), do: "output_text"

  # Keeps the newest items that fit beside the closing line; the first one
  # that does not fit ends the walk, so everything older goes with it.
  defp within_bound(items) do
    budget = @input_max_bytes - byte_size(@closing)

    items
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn item, {kept, used} ->
      next = used + text_bytes(item)
      if next <= budget, do: {:cont, {[item | kept], next}}, else: {:halt, {kept, used}}
    end)
    |> elem(0)
  end

  defp item(role, part_type, text) do
    %{type: "message", role: role, content: [%{type: part_type, text: text}]}
  end

  defp text_bytes(%{content: [%{text: text}]}), do: byte_size(text)
end
