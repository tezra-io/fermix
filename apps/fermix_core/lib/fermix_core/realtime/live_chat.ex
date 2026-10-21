defmodule FermixCore.Realtime.LiveChat do
  @moduledoc """
  What a voice call that hands its tasks to Fermix is given of the chat (M56
  §4.3, D5, D6): the context a call in the chat's conversation starts with,
  GPT Live's `session.input` (`input/1`) and Grok's conversation items
  (`context/2`, M70 §07).

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
  The chain is the call's own voice provider, never a fixed one: OpenAI being
  granted history says nothing about SpaceXAI (M70 §07), and the backend that
  answers a task is a separate recipient again.
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

  @typedoc "One line of what a call starts with, before any wire shapes it."
  @type entry :: %{role: :context | :user | :assistant, text: String.t()}

  @type item :: %{
          type: String.t(),
          role: String.t(),
          content: [%{type: String.t(), text: String.t()}]
        }

  @doc """
  Whether text stamped as Computer History content may be given to a voice
  spoken by `provider` (M56 §9): only when that provider, the voice's one hop,
  is granted history, the rule a turn's own history is masked by. A
  hand-off's reply so stamped is shown in the chat instead of said.
  """
  @spec history_permitted?(atom()) :: boolean()
  def history_permitted?(provider) when is_atom(provider),
    do: Gate.chain_permits_history?(chain(provider))

  @doc "How much of the chat a call asks the bridge for."
  @spec window_bounds() :: %{messages: pos_integer(), gists: pos_integer()}
  def window_bounds, do: %{messages: @messages, gists: @gists}

  @doc "The byte bound on the whole input (4 bytes a token, half the provider's 8,192)."
  @spec input_max_bytes() :: pos_integer()
  def input_max_bytes, do: @input_max_bytes

  @doc """
  What a call whose voice `provider` speaks starts with: the gists of earlier
  calls as one `:context` line, oldest first; the chat messages as `:user` and
  `:assistant` lines, oldest first; and a closing `:context` line. `[]` when
  there is no context at all. Only the newest `window_bounds/0` of each are
  used, whatever the window holds, and a gist drawn from Computer History is
  left out unless the voice may carry it (`history_permitted?/1`).

  Raises `ArgumentError` on a message whose role is not `user` or `assistant`:
  a window holding anything else broke the bridge's contract.
  """
  @spec context(%{messages: [map()], gists: [CallRecord.gist()]}, atom()) :: [entry()]
  def context(%{messages: messages, gists: gists}, provider)
      when is_list(messages) and is_list(gists) and is_atom(provider) do
    context =
      gist_entries(given_gists(gists, provider)) ++
        chat_entries(Enum.take(messages, -@messages), provider)

    case within_bound(context) do
      [] -> []
      kept -> kept ++ [entry(:context, @closing)]
    end
  end

  @doc """
  GPT Live's `session.input` for a window (`context/2` for OpenAI): the
  `:context` lines as `developer` items, the chat as `user` and `assistant`
  items.
  """
  @spec input(%{messages: [map()], gists: [CallRecord.gist()]}) :: [item()]
  def input(%{messages: _messages, gists: _gists} = window),
    do: window |> context(:openai) |> Enum.map(&live_item/1)

  @doc """
  Whether the context built from `window` gives a voice spoken by `provider`
  anything drawn from Computer History (M56 §9): only when that voice may
  carry it, and then when a message or a gist the context uses is stamped. A
  call that starts so passes the mark to its gist.
  """
  @spec carries_taint?(%{messages: [map()], gists: [CallRecord.gist()]}, atom()) :: boolean()
  def carries_taint?(%{messages: messages, gists: gists}, provider)
      when is_list(messages) and is_list(gists) and is_atom(provider) do
    history_permitted?(provider) and
      (Enum.any?(Enum.take(messages, -@messages), &Taint.tainted?/1) or
         Enum.any?(Enum.take(gists, @gists), & &1.tainted))
  end

  @doc "The size of an input, for telemetry: its items and their text bytes, never the text."
  @spec input_size([item()]) :: %{input_items: non_neg_integer(), input_bytes: non_neg_integer()}
  def input_size(items) when is_list(items) do
    %{input_items: length(items), input_bytes: items |> Enum.map(&item_bytes/1) |> Enum.sum()}
  end

  @doc "The size of a context (`context/2`), for telemetry: its lines and their bytes, never the text."
  @spec context_size([entry()]) ::
          %{input_items: non_neg_integer(), input_bytes: non_neg_integer()}
  def context_size(entries) when is_list(entries) do
    %{input_items: length(entries), input_bytes: entries |> Enum.map(&text_bytes/1) |> Enum.sum()}
  end

  @doc """
  The line a call is told when the owner types in the chat (`{:typed, text}`)
  or the chat answers (`{:answered, message}`, the chat's assistant message as
  its store holds it), cut to 300 characters; `:drop` for a message with no
  text or an answer a voice spoken by `provider` may not be given.
  """
  @spec mirror_line({:typed, String.t()} | {:answered, map()}, atom()) ::
          {:ok, String.t()} | :drop
  def mirror_line({:typed, text}, provider) when is_binary(text) and is_atom(provider),
    do: mirrored(@typed_prefix, text)

  def mirror_line({:answered, %{role: "assistant", content: content} = message}, provider)
      when is_binary(content) and is_atom(provider) do
    case Taint.mask_for_chain([message], chain(provider)) do
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

  # The route the taint gate reads for a voice: one hop, the provider that
  # speaks it, which is never local, so a tainted line passes only when that
  # provider is granted history.
  defp chain(provider), do: [%{provider: provider}]

  # The newest three, less any the voice may not carry.
  defp given_gists(gists, provider) do
    permitted? = history_permitted?(provider)

    gists
    |> Enum.take(@gists)
    |> Enum.reject(&(&1.tainted and not permitted?))
  end

  # Read newest first, told oldest first, so the whole context runs in time order.
  defp gist_entries([]), do: []

  defp gist_entries(gists) do
    lines = gists |> Enum.reverse() |> Enum.map_join("\n", &("- " <> String.trim(&1.gist)))
    [entry(:context, @gists_heading <> "\n" <> lines)]
  end

  defp chat_entries(messages, provider) do
    messages
    |> Enum.map(&chat_message!/1)
    |> Enum.reject(&silent_reply?/1)
    |> Taint.mask_for_chain(chain(provider))
    |> Enum.flat_map(&chat_entry/1)
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

  defp chat_entry(%{role: role, content: content}) do
    case LiveText.summary(content, @message_max_chars) do
      "" -> []
      text -> [entry(chat_role(role), text)]
    end
  end

  defp chat_role("user"), do: :user
  defp chat_role("assistant"), do: :assistant

  # Keeps the newest lines that fit beside the closing line; the first one
  # that does not fit ends the walk, so everything older goes with it.
  defp within_bound(entries) do
    budget = @input_max_bytes - byte_size(@closing)

    entries
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn entry, {kept, used} ->
      next = used + text_bytes(entry)
      if next <= budget, do: {:cont, {[entry | kept], next}}, else: {:halt, {kept, used}}
    end)
    |> elem(0)
  end

  defp entry(role, text), do: %{role: role, text: text}

  defp live_item(%{role: :context, text: text}), do: item("developer", "input_text", text)
  defp live_item(%{role: :user, text: text}), do: item("user", "input_text", text)
  defp live_item(%{role: :assistant, text: text}), do: item("assistant", "output_text", text)

  defp item(role, part_type, text) do
    %{type: "message", role: role, content: [%{type: part_type, text: text}]}
  end

  defp text_bytes(%{text: text}), do: byte_size(text)
  defp item_bytes(%{content: [%{text: text}]}), do: byte_size(text)
end
