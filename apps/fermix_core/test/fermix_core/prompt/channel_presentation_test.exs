defmodule FermixCore.Prompt.ChannelPresentationTest do
  use ExUnit.Case, async: true

  alias FermixCore.Prompt.ChannelPresentation

  @chat_channels ["telegram", "whatsapp", "discord", "slack", "signal", "imessage"]

  describe "note/2" do
    test "every chat channel gets the shared chat-surface core" do
      for channel <- @chat_channels do
        note = ChannelPresentation.note(channel, "private")

        assert is_binary(note), "expected a presentation note for #{channel}"
        assert note =~ "phone-width chat surface"
        assert note =~ "Lead with the answer"
        assert note =~ "No markdown tables and no horizontal rules"
        assert note =~ "quote block"
      end
    end

    test "machine and terminal surfaces carry no presentation posture" do
      assert ChannelPresentation.note("acp", "private") == nil
      assert ChannelPresentation.note("cli", "private") == nil
      assert ChannelPresentation.note("voice", nil) == nil
      assert ChannelPresentation.note(nil, nil) == nil
      assert ChannelPresentation.note("not-a-channel", nil) == nil
    end

    test "the note is byte-identical across calls for the same surface" do
      for channel <- @chat_channels, chat_type <- ["private", "group", nil] do
        first = ChannelPresentation.note(channel, chat_type)
        second = ChannelPresentation.note(channel, chat_type)

        assert first == second
      end
    end

    test "telegram earns its own line about collapsed quote blocks" do
      note = ChannelPresentation.note("telegram", "private")

      assert note =~ "Telegram renders a quote block collapsed"
      refute note =~ "Discord"
    end

    test "discord earns its own line about the message cap" do
      note = ChannelPresentation.note("discord", "private")

      assert note =~ "Discord caps a single message"
      refute note =~ "Telegram"
    end

    # M54 §8.1: iMessage renders no markup at all, which the shared core does
    # not say on its own.
    test "imessage earns its own line about plain text" do
      note = ChannelPresentation.note("imessage", "private")

      assert note =~
               "- iMessage shows plain text only: no headings, bold or tables survive, so lead " <>
                 "with the answer and keep lists short."

      refute note =~ "Telegram"
    end

    # M72 decision 5: the Mac chat draws the places a reply links as cards and
    # a map beside it. It is a window, not a phone-width bubble, so it earns
    # that one line and none of the shared core.
    test "the Mac chat gets one line of its own about place cards" do
      for chat_type <- [nil, "private", "group"] do
        note = ChannelPresentation.note("companion", chat_type)

        assert is_binary(note)
        assert [_one_line] = String.split(note, "\n")
        assert note =~ "place_search"
        assert note =~ "card"
        assert note =~ "map"
        assert note =~ "link every place by name"
        refute note =~ "phone-width chat surface"
      end
    end

    test "a shared chat appends the addressing line and a DM does not" do
      for group_type <- ["group", "supergroup", "channel", "guild", "mpim"] do
        assert ChannelPresentation.note("telegram", group_type) =~ "This is a shared chat"
      end

      for dm_type <- ["private", "im"] do
        refute ChannelPresentation.note("telegram", dm_type) =~ "This is a shared chat"
      end
    end

    test "an absent or unrecognised chat type omits the addressing line" do
      refute ChannelPresentation.note("slack", nil) =~ "This is a shared chat"
      refute ChannelPresentation.note("slack", "something_new") =~ "This is a shared chat"
    end

    test "the group variant is the DM note plus exactly one line" do
      dm = ChannelPresentation.note("signal", "private")
      group = ChannelPresentation.note("signal", "group")

      assert String.starts_with?(group, dm <> "\n")
      assert length(String.split(group, "\n")) == length(String.split(dm, "\n")) + 1
    end

    test "carries no timestamp or other per-turn variance" do
      note = ChannelPresentation.note("telegram", "private")

      refute note =~ ~r/\d{4}-\d{2}-\d{2}/
      refute note =~ "Current date"
    end
  end

  # EVENTS_DRAWN_AS_CARDS §04: one line where the connection draws events, and
  # nothing anywhere else.
  describe "events_line/2" do
    test "says the events are drawn on a drawing companion or phone turn, else nothing" do
      for channel <- ["companion", "mobile"] do
        line = ChannelPresentation.events_line(channel, true)
        assert line =~ "drawn under your reply"
        assert line =~ "confirm in a sentence"
      end

      for {channel, draws?} <- [
            {"companion", false},
            {"mobile", false},
            {"telegram", true},
            {"telegram", false},
            {nil, true}
          ] do
        assert ChannelPresentation.events_line(channel, draws?) == nil, inspect(channel)
      end
    end

    # A block carries at most `ReplyBlocks.max_events/0` events, so the line
    # says no more are drawn and has the reply say how many more there are:
    # the rest are in neither the card nor the text otherwise.
    test "says how many a reply draws at most, and to say how many more there are" do
      most = Integer.to_string(FermixCore.ReplyBlocks.max_events())

      for channel <- ["companion", "mobile"] do
        line = ChannelPresentation.events_line(channel, true)
        assert line =~ "at most #{most}"
        assert line =~ "more than #{most}, say how many more"
      end
    end
  end

  # A call that is only said hears what changed in a list or a trip: the
  # OpenAI Realtime call, whose tool context names no channel and is known by
  # the voice-call fact, and a Live or Grok call's hand-off in a private call.
  # Nothing is drawn on a call, and a screen's lines (write the list, link
  # each stop) would be read aloud. A hand-off in a chat call shows what it
  # cannot say in the owner's chat, as text, so it keeps those lines.
  describe "a call's lines" do
    test "the voice channel says what changed, never a screen's lines" do
      list = ChannelPresentation.checklist_line("voice", false)
      trip = ChannelPresentation.trip_line("voice", false)

      assert list ==
               "On a call, say what changed in a list; read its items aloud only when asked."

      assert trip ==
               "On a call, say what changed in a trip; read its days aloud only when asked, " <>
                 "and never read a link aloud."

      assert ChannelPresentation.checklist_line("voice", true) == list
      assert ChannelPresentation.trip_line("voice", true) == trip
      refute ChannelPresentation.checklist_line("telegram", false) == list
      refute ChannelPresentation.trip_line("telegram", false) == trip
    end

    test "a call that is only said is the voice channel's; every other context is its own" do
      assert ChannelPresentation.channel_of(%{computer_use_origin: :voice}) == "voice"

      assert ChannelPresentation.channel_of(%{channel: "voice", computer_use_origin: :voice}) ==
               "voice"

      private = %{channel: "voice", computer_use_origin: :voice, voice_conversation: "private"}
      assert ChannelPresentation.channel_of(private) == "voice"

      # A chat call's hand-off: its shown part is text in the owner's chat,
      # which draws nothing, so it is told the lines of no drawing surface.
      chat = %{private | voice_conversation: "chat"}
      assert ChannelPresentation.channel_of(chat) == nil

      assert ChannelPresentation.checklist_line(ChannelPresentation.channel_of(chat), false) ==
               ChannelPresentation.checklist_line("telegram", false)

      assert ChannelPresentation.channel_of(%{
               channel: "telegram",
               computer_use_origin: :interactive
             }) == "telegram"

      assert ChannelPresentation.channel_of(%{channel: "companion"}) == "companion"
      assert ChannelPresentation.channel_of(%{computer_use_origin: :unattended}) == nil
    end
  end
end
