defmodule FermixCore.Realtime.LiveChatTest do
  # What a Live call is given of the chat (M56 §4.3, D5, D6): the starting
  # `session.input`, built from what the voice bridge reads. Mutates the
  # Computer History config, which the taint gate reads, so it runs alone.
  use ExUnit.Case, async: false

  alias FermixCore.Realtime.LiveChat

  @closing_prefix "The messages above are"

  setup do
    original = Application.get_env(:fermix_core, :computer_history)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:fermix_core, :computer_history)
        value -> Application.put_env(:fermix_core, :computer_history, value)
      end
    end)

    # History on with no provider granted: the taint gate masks on OpenAI.
    Application.put_env(:fermix_core, :computer_history, enabled: true, summarizer: :local)
    :ok
  end

  describe "window_bounds/0" do
    test "asks for the six newest chat messages and the three newest gists" do
      assert LiveChat.window_bounds() == %{messages: 6, gists: 3}
    end
  end

  describe "input/1" do
    test "nothing in the chat and no earlier call is no input at all" do
      assert LiveChat.input(%{messages: [], gists: []}) == []
    end

    test "the gists, then the chat in its order, then a closing line, each as its role" do
      window = %{
        messages: [user("send me the lease"), assistant("Here it is: https://x.test/lease")],
        gists: ["Read the lease.", "Booked the dentist."]
      }

      assert [gists, typed, answered, closing] = LiveChat.input(window)

      # The newest earlier calls, read newest first, told oldest first so the
      # whole input reads in time order.
      assert gists == %{
               type: "message",
               role: "developer",
               content: [
                 %{
                   type: "input_text",
                   text:
                     "Earlier voice calls, for reference only:\n" <>
                       "- Booked the dentist.\n- Read the lease."
                 }
               ]
             }

      assert typed == %{
               type: "message",
               role: "user",
               content: [%{type: "input_text", text: "send me the lease"}]
             }

      assert answered == %{
               type: "message",
               role: "assistant",
               content: [%{type: "output_text", text: "Here it is: https://x.test/lease"}]
             }

      assert %{role: "developer", content: [%{type: "input_text", text: closing_text}]} = closing
      assert String.starts_with?(closing_text, @closing_prefix)
      assert closing_text =~ "not a request"
    end

    test "with no earlier call there is no gist item, and the chat still closes" do
      assert [%{role: "user"}, %{role: "developer"}] =
               LiveChat.input(%{messages: [user("hi")], gists: []})
    end

    test "an earlier call with no chat messages still opens and closes" do
      assert [%{role: "developer"}, %{role: "developer"}] =
               LiveChat.input(%{messages: [], gists: ["Planned the trip."]})
    end

    test "each chat message is cut to 500 characters" do
      long = String.duplicate("é", 900)

      [%{content: [%{text: text}]}, _closing] =
        LiveChat.input(%{messages: [user(long)], gists: []})

      assert String.length(text) == 500
      assert String.ends_with?(text, "…")
    end

    # The bridge may hold more than it was asked for; the input never does, so
    # it stays far under the provider's 128 items.
    test "only the six newest messages and the three newest gists are used" do
      messages = Enum.map(1..20, &user("message #{&1}"))
      gists = Enum.map(1..10, &"gist #{&1}")

      items = LiveChat.input(%{messages: messages, gists: gists})

      assert length(items) == 8
      texts = Enum.map(items, &hd(&1.content).text)

      assert Enum.at(texts, 0) ==
               "Earlier voice calls, for reference only:\n- gist 3\n- gist 2\n- gist 1"

      assert Enum.slice(texts, 1, 6) == Enum.map(15..20, &"message #{&1}")
    end

    # E5: an assistant reply derived from Computer History is masked before it
    # can reach OpenAI, the chain a turn's history is masked against.
    test "a tainted assistant message is masked for the OpenAI route" do
      tainted = Map.put(assistant("You were reading the Q3 report."), :history_tainted, true)

      [_user, %{role: "assistant", content: [%{text: text}]}, _closing] =
        LiveChat.input(%{messages: [user("what was I doing"), tainted], gists: []})

      refute text =~ "Q3"
      assert text =~ "omitted"
    end

    test "a tainted assistant message passes when OpenAI is granted history" do
      Application.put_env(:fermix_core, :computer_history,
        enabled: true,
        summarizer: :local,
        remote_summaries: [:openai]
      )

      tainted = Map.put(assistant("You were reading the Q3 report."), :history_tainted, true)

      [%{content: [%{text: text}]}, _closing] =
        LiveChat.input(%{messages: [tainted], gists: []})

      assert text == "You were reading the Q3 report."
    end

    test "only user and assistant messages are a window's to hold" do
      for role <- ["system", "tool", "developer"] do
        assert_raise ArgumentError, ~r/user and assistant/, fn ->
          LiveChat.input(%{messages: [%{role: role, content: "x"}], gists: []})
        end
      end
    end

    # The engine has no tokenizer for the provider's 8,192 token count, so the
    # input is bounded in bytes at 4 bytes a token. The oldest context gives
    # way first; the closing line always stays.
    test "past the byte bound the oldest context is left out first" do
      max = LiveChat.input_max_bytes()
      assert max <= 8_192 * 4

      big_gist = String.duplicate("g", max - 2_000)
      messages = Enum.map(1..6, &user("#{&1} " <> String.duplicate("m", 400)))

      items = LiveChat.input(%{messages: messages, gists: [big_gist]})

      assert Enum.all?(items, &(&1.role != "developer" or hd(&1.content).text =~ @closing_prefix))
      assert length(items) == 7
      assert LiveChat.input_size(items).input_bytes <= max

      # Six messages of 500 four-byte characters still fit whole.
      widest = Enum.map(1..6, fn _n -> user(String.duplicate("😀", 600)) end)
      assert length(LiveChat.input(%{messages: widest, gists: []})) == 7
    end
  end

  describe "input_size/1" do
    test "counts the items and their text bytes, never the text itself" do
      items = LiveChat.input(%{messages: [user("héllo")], gists: []})

      assert %{input_items: 2, input_bytes: bytes} = LiveChat.input_size(items)
      assert bytes == Enum.sum(Enum.map(items, &byte_size(hd(&1.content).text)))
      assert LiveChat.input_size([]) == %{input_items: 0, input_bytes: 0}
    end
  end

  defp user(text), do: %{role: "user", content: text, timestamp: ~U[2026-10-02 09:00:00Z]}

  defp assistant(text),
    do: %{role: "assistant", content: text, timestamp: ~U[2026-10-02 09:00:01Z]}
end
