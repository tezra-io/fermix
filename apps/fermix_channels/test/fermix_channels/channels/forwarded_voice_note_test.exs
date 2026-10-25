defmodule FermixChannels.Channels.ForwardedVoiceNoteTest do
  # A voice note is the owner's own words only when the owner recorded it. A
  # forwarded one was recorded by someone else, so the channel declares it as
  # plain audio (`:audio`, never `:voice`): it is still transcribed, and it counts
  # as content someone else could have written (`UntrustedContent`).
  # async: false — WhatsApp reads whether its ingress is on from app env.
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Telegram
  alias FermixChannels.Channels.WhatsApp
  alias FermixCore.Attachments
  alias FermixCore.Capabilities.UntrustedContent

  # What the gateway builds from a declared audio attachment once transcribed:
  # the hint is copied as declared, and decides whether it counts.
  defp sources(%{hint: hint}) do
    UntrustedContent.attachment_sources([
      %Attachments{kind: :audio, mime_type: "audio/ogg", hint: hint, status: :transcribed}
    ])
  end

  describe "Telegram" do
    defp voice_update(extra) do
      %{
        "message" =>
          Map.merge(
            %{
              "message_id" => 40,
              "voice" => %{"file_id" => "voice-40", "duration" => 3, "file_size" => 900},
              "chat" => %{"id" => 123},
              "from" => %{"id" => 111, "username" => "alice"}
            },
            extra
          )
      }
    end

    test "the owner's own voice note is declared a voice recording" do
      assert {:ok, [msg]} = Telegram.parse_update(voice_update(%{}))
      assert [%{hint: :voice, mime_type: "audio/ogg"}] = msg.attachments
    end

    test "a forwarded voice note is declared plain audio" do
      forwarded = [
        %{"forward_origin" => %{"type" => "user", "date" => 1_760_000_000}},
        %{"forward_from" => %{"id" => 222, "first_name" => "Brook"}},
        %{"forward_sender_name" => "Brook"},
        %{"forward_date" => 1_760_000_000}
      ]

      for marker <- forwarded do
        assert {:ok, [msg]} = Telegram.parse_update(voice_update(marker))
        assert [%{hint: :audio, mime_type: "audio/ogg"}] = msg.attachments, inspect(marker)
      end
    end
  end

  describe "WhatsApp" do
    setup do
      previous = Application.get_env(:fermix_channels, :whatsapp)
      Application.put_env(:fermix_channels, :whatsapp, enabled: true, mode: :webhook)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:fermix_channels, :whatsapp, previous),
          else: Application.delete_env(:fermix_channels, :whatsapp)
      end)

      :ok
    end

    # The Cloud API shape: a voice note is `type: "audio"` with `audio.voice`
    # true; an audio file the owner attached has no `voice` flag.
    defp audio_webhook(audio, extra) do
      message =
        Map.merge(
          %{
            "from" => "15551234567",
            "id" => "wamid.voice",
            "timestamp" => "1760000000",
            "type" => "audio",
            "audio" => Map.merge(%{"id" => "voice-media-id", "mime_type" => "audio/ogg"}, audio)
          },
          extra
        )

      %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "id" => "waba-id",
            "changes" => [
              %{
                "field" => "messages",
                "value" => %{
                  "messaging_product" => "whatsapp",
                  "metadata" => %{"phone_number_id" => "123456789"},
                  "contacts" => [%{"wa_id" => "15551234567", "profile" => %{"name" => "Alice"}}],
                  "messages" => [message]
                }
              }
            ]
          }
        ]
      }
    end

    test "the owner's own voice note is a voice recording and does not count" do
      assert {:ok, [msg]} = WhatsApp.parse_webhook(audio_webhook(%{"voice" => true}, %{}))
      assert [%{hint: :voice} = declared] = msg.attachments
      assert sources(declared) == MapSet.new()
    end

    test "a forwarded voice note is plain audio and counts" do
      for context <- [%{"forwarded" => true}, %{"frequently_forwarded" => true}] do
        webhook = audio_webhook(%{"voice" => true}, %{"context" => context})
        assert {:ok, [msg]} = WhatsApp.parse_webhook(webhook)
        assert [%{hint: :audio} = declared] = msg.attachments, inspect(context)
        assert sources(declared) == MapSet.new([{:attachment, "attached audio"}])
      end
    end

    test "an attached audio file is plain audio and counts" do
      assert {:ok, [msg]} = WhatsApp.parse_webhook(audio_webhook(%{}, %{}))
      assert [%{hint: :audio} = declared] = msg.attachments
      assert sources(declared) == MapSet.new([{:attachment, "attached audio"}])
    end
  end
end
