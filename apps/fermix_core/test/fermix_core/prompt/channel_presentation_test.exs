defmodule FermixCore.Prompt.ChannelPresentationTest do
  use ExUnit.Case, async: true

  alias FermixCore.Prompt.ChannelPresentation

  @chat_channels ["telegram", "whatsapp", "discord", "slack", "signal"]

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
end
