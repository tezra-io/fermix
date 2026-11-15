defmodule FermixCore.Realtime.CallGoodbyeTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.CallGoodbye

  describe "goodbye?/2" do
    test "a whole turn of lead-ins, one closing and tails is a goodbye" do
      for text <- [
            "Bye.",
            "bye-bye",
            "Good-bye!",
            "Goodbye",
            "Okay, thanks, bye.",
            "OK bye",
            "Thank you so much, goodbye.",
            "Thanks, bye, thanks",
            "Perfect. That's all, bye!",
            "That’s it, goodbye",
            "Um, okay, uh, bye",
            "Bye for now",
            "Alright, goodbye for now.",
            "All right, good bye then",
            "Cheers, bye",
            "Bye, Fermix"
          ] do
        assert CallGoodbye.goodbye?(text, nil), "expected a goodbye: #{inspect(text)}"
      end
    end

    test "a request that mentions a goodbye, an answer or a half sentence is not" do
      for text <- [
            "Tell Sam bye",
            "Don't hang up",
            "Say goodbye to the team for me",
            "See you at five",
            "see you",
            "talk later",
            "later",
            "cheers",
            "thanks",
            "that's all",
            "that's it",
            "okay",
            "",
            "   ",
            "Bye bye bye bye bye bye bye bye bye",
            "Okay thanks so much for everything bye",
            "Remind me to say bye to Sam at five"
          ] do
        refute CallGoodbye.goodbye?(text, nil), "expected no goodbye: #{inspect(text)}"
      end
    end

    test "only bye and goodbye close a turn: every other farewell keeps the call" do
      for text <- [
            "Alright, talk to you later.",
            "All right, catch you later then",
            "Cool, see ya",
            "That's it, take care",
            "Sounds good, good night",
            "gotta go",
            "Got to go now",
            "Okay, hang up",
            "End the call",
            "Okay, see you",
            "See you then",
            "Okay, talk later"
          ] do
        refute CallGoodbye.goodbye?(text, nil), "expected no goodbye: #{inspect(text)}"
      end
    end

    test "eight words is the most a goodbye has, fillers not counted" do
      assert CallGoodbye.goodbye?("okay alright cool great perfect thanks bye now", nil)
      refute CallGoodbye.goodbye?("okay okay alright cool great perfect thanks bye now", nil)
      assert CallGoodbye.goodbye?("um uh okay alright cool great perfect thanks bye now", nil)
    end

    test "the configured assistant name is a tail, and only a tail" do
      assert CallGoodbye.goodbye?("Bye, Nova", "Nova")
      assert CallGoodbye.goodbye?("Okay thanks, bye Nova Prime", "Nova Prime")
      refute CallGoodbye.goodbye?("Bye, Nova", nil)
      refute CallGoodbye.goodbye?("Nova", "Nova")
      refute CallGoodbye.goodbye?("Nova bye", "Nova")
    end

    test "text past the byte bound is not a goodbye" do
      refute CallGoodbye.goodbye?("bye" <> String.duplicate(" ", 300), nil)
    end
  end

  describe "a call that ends on a goodbye" do
    test "ends once the reply to the goodbye has played out" do
      goodbye = said(CallGoodbye.new(nil), [{1_000, "Okay, thanks, "}, {1_400, "bye."}])
      goodbye = CallGoodbye.reply_started(goodbye, 2_200)

      assert {:end, _goodbye} = CallGoodbye.reply_played_out(goodbye)
    end

    test "a goodbye's transcript that lands after the reply played out ends the call then" do
      goodbye = CallGoodbye.new(nil) |> CallGoodbye.reply_started(2_200)
      assert {:cont, goodbye} = CallGoodbye.reply_played_out(goodbye)

      assert {:end, _goodbye} = CallGoodbye.owner_words(goodbye, "Bye.", 1_500, 1_700)
    end

    test "words spoken after the reply began start the next turn and cannot end the call" do
      goodbye = said(CallGoodbye.new(nil), [{1_000, "What's the weather?"}])
      goodbye = CallGoodbye.reply_started(goodbye, 2_000)
      # The reply's own echo, heard through the microphone.
      assert {:cont, goodbye} = CallGoodbye.owner_words(goodbye, " Bye!", 2_600, 2_800)

      assert {:cont, _goodbye} = CallGoodbye.reply_played_out(goodbye)
    end

    test "the reply's echo cannot keep the call open either" do
      goodbye = said(CallGoodbye.new(nil), [{1_000, "bye"}])
      goodbye = CallGoodbye.reply_started(goodbye, 2_000)

      assert {:cont, goodbye} =
               CallGoodbye.owner_words(goodbye, " Bye, Sam! Talk soon.", 2_300, 3_100)

      assert {:end, _goodbye} = CallGoodbye.reply_played_out(goodbye)
    end

    test "an interruption of the reply forgets the goodbye, late words included" do
      goodbye = said(CallGoodbye.new(nil), [{1_000, "bye "}])
      goodbye = goodbye |> CallGoodbye.reply_started(2_000) |> CallGoodbye.interrupted()

      assert {:cont, goodbye} = CallGoodbye.reply_played_out(goodbye)
      assert {:cont, _goodbye} = CallGoodbye.owner_words(goodbye, "thanks", 1_800, 2_000)
    end

    test "a reply that starts more than ten seconds after the goodbye's last word does not end the call" do
      late = said(CallGoodbye.new(nil), [{1_000, "bye"}]) |> CallGoodbye.reply_started(11_001)
      assert {:cont, _late} = CallGoodbye.reply_played_out(late)

      timely = said(CallGoodbye.new(nil), [{1_000, "bye"}]) |> CallGoodbye.reply_started(11_000)
      assert {:end, _timely} = CallGoodbye.reply_played_out(timely)
    end

    test "the next reply forgets the turn the last one answered" do
      goodbye = said(CallGoodbye.new(nil), [{1_000, "bye"}]) |> CallGoodbye.reply_started(2_000)
      goodbye = CallGoodbye.reply_started(goodbye, 3_000)

      assert {:cont, goodbye} = CallGoodbye.reply_played_out(goodbye)
      assert {:cont, _goodbye} = CallGoodbye.owner_words(goodbye, "bye", 1_500, 1_700)
    end

    test "a goodbye after a request is not a goodbye: the whole turn counts" do
      goodbye =
        said(CallGoodbye.new(nil), [
          {1_000, "Remind me to call the vet at noon, "},
          {2_000, "bye"}
        ])

      goodbye = CallGoodbye.reply_started(goodbye, 3_000)
      assert {:cont, _goodbye} = CallGoodbye.reply_played_out(goodbye)
    end

    test "fragments join in the order they were spoken, not the order they arrived" do
      goodbye = said(CallGoodbye.new(nil), [{1_400, "bye"}, {1_000, "okay "}])
      goodbye = CallGoodbye.reply_started(goodbye, 2_000)

      assert {:end, _goodbye} = CallGoodbye.reply_played_out(goodbye)
    end

    test "a turn past the fragment bound is too long to be a goodbye, on its own side of the reply" do
      long = Enum.map(1..40, &{&1, "a "})
      goodbye = said(CallGoodbye.new(nil), long ++ [{100, "bye"}])
      goodbye = CallGoodbye.reply_started(goodbye, 1_000)
      assert {:cont, goodbye} = CallGoodbye.reply_played_out(goodbye)

      # The spill was all before the reply: the next turn is whole again.
      goodbye = goodbye |> said([{1_500, "bye"}]) |> CallGoodbye.reply_started(2_000)
      assert {:end, _goodbye} = CallGoodbye.reply_played_out(goodbye)
    end

    # GPT-Live may begin its reply in a pause mid-sentence; the owner's words
    # that carry on without a longer pause are still the turn it answers.
    test "words carrying on the owner's speech past the reply's start join the turn it answers" do
      goodbye = said(CallGoodbye.new(nil), [{6_400, "Okay"}, {7_200, ", thanks"}])
      goodbye = CallGoodbye.reply_started(goodbye, 7_600)
      assert {:cont, goodbye} = CallGoodbye.owner_words(goodbye, ". Bye", 7_800, 8_000)

      assert {:end, _goodbye} = CallGoodbye.reply_played_out(goodbye)
    end

    test "carried-on words whose transcript lands before the reply's own still join its turn" do
      goodbye =
        said(CallGoodbye.new(nil), [{6_400, "Okay"}, {7_200, ", thanks"}, {7_800, ". Bye"}])

      goodbye = CallGoodbye.reply_started(goodbye, 7_600)

      assert {:end, _goodbye} = CallGoodbye.reply_played_out(goodbye)
    end

    test "carried-on words that land after the reply played out end the call then" do
      goodbye = said(CallGoodbye.new(nil), [{6_400, "Okay, thanks"}])
      goodbye = CallGoodbye.reply_started(goodbye, 6_900)
      assert {:cont, goodbye} = CallGoodbye.reply_played_out(goodbye)

      assert {:end, _goodbye} = CallGoodbye.owner_words(goodbye, " bye", 7_500, 7_700)
    end

    test "a request carried on past the reply's start keeps the call up" do
      goodbye = said(CallGoodbye.new(nil), [{1_000, "Okay, bye"}])
      goodbye = CallGoodbye.reply_started(goodbye, 1_400)
      {:cont, goodbye} = CallGoodbye.owner_words(goodbye, " and water the ferns", 1_600, 2_400)

      assert {:cont, _goodbye} = CallGoodbye.reply_played_out(goodbye)
    end

    test "a pause of more than a second after the owner's last word starts the next turn" do
      goodbye = said(CallGoodbye.new(nil), [{1_000, 1_400, "Okay, thanks"}])
      goodbye = CallGoodbye.reply_started(goodbye, 1_600)
      assert {:cont, goodbye} = CallGoodbye.owner_words(goodbye, " bye", 2_401, 2_600)
      assert {:cont, goodbye} = CallGoodbye.reply_played_out(goodbye)

      carried = said(CallGoodbye.new(nil), [{1_000, 1_400, "Okay, thanks"}])
      carried = CallGoodbye.reply_started(carried, 1_600)
      assert {:cont, carried} = CallGoodbye.owner_words(carried, " bye", 2_400, 2_600)
      assert {:end, _carried} = CallGoodbye.reply_played_out(carried)

      # The goodbye said after that pause is a turn of its own, for the next reply.
      goodbye = CallGoodbye.reply_started(goodbye, 3_000)
      assert {:end, _goodbye} = CallGoodbye.reply_played_out(goodbye)
    end

    test "a transcript with no times of its own is dated by its start" do
      goodbye = said(CallGoodbye.new(nil), [{1_000, 0, "bye"}])
      goodbye = CallGoodbye.reply_started(goodbye, 1_500)

      assert {:end, _goodbye} = CallGoodbye.reply_played_out(goodbye)
    end

    test "a reply with no turn before it, the greeting, never ends the call" do
      goodbye = CallGoodbye.reply_started(CallGoodbye.new("Nova"), 500)
      assert {:cont, _goodbye} = CallGoodbye.reply_played_out(goodbye)
    end
  end

  # Each fragment as `{start_ms, text}`, spoken for 200 ms as GPT-Live dates
  # words, or as `{start_ms, end_ms, text}`.
  defp said(goodbye, fragments) do
    Enum.reduce(fragments, goodbye, fn fragment, acc ->
      {start_ms, end_ms, text} = timed(fragment)
      {:cont, acc} = CallGoodbye.owner_words(acc, text, start_ms, end_ms)
      acc
    end)
  end

  defp timed({start_ms, text}), do: {start_ms, start_ms + 200, text}
  defp timed({_start_ms, _end_ms, _text} = fragment), do: fragment
end
